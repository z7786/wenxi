import 'package:asterlink/data/providers/baidu_link_service.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const _personal = BrowseSession(
  platform: CloudPlatform.baidu,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: '/',
);
const _encodedKey = 'a%2Bb%2Fc%3D';
const _share = BrowseSession(
  platform: CloudPlatform.baidu,
  mode: BrowseMode.share,
  title: 'fixture',
  rootId: '/',
  metadata: {
    'shortId': 'fixture',
    'sekey': _encodedKey,
    'shareId': '123',
    'uk': '456',
  },
);
const _file = CloudFile(
  id: '789',
  name: '测试 + 文件.bin',
  token: '/视频/测试 + 文件.bin',
  size: 42,
);
Credential _credential([Map<String, String> extra = const {}]) => Credential(
  'fixture',
  {'primary': 'BDUSS=fixture; BDCLND=old; bdclnd=also-old', ...extra},
  updatedAt: 1,
);
ParsedLink _link({String? passcode}) => ParsedLink(
  source: 'fixture',
  url: 'https://pan.baidu.com/s/1fixture',
  kind: LinkKind.cloudShare,
  platform: CloudPlatform.baidu,
  shareId: 'fixture',
  passcode: passcode,
);
Map<String, String> _form(RecordedRequest r) =>
    Uri.splitQueryString(r.body as String);
Matcher _message(String part) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(part)),
);
Json _shareFiles() => {
  'errno': 0,
  'share_id': '123',
  'uk': '456',
  'list': [
    {
      'fs_id': '9007199254740993',
      'path': '/共享目录 + 中文',
      'isdir': '1',
      'server_filename': '共享目录 + 中文',
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Baidu login and capacity', () {
    test(
      'Login cannot succeed on quota alone when both file-list routes reject it',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path == '/api/list'
              ? jsonResponse({'errno': -6})
              : jsonResponse({'errno': 0, 'used': 1, 'total': 100}),
        );
        final connector = BaiduConnector(http);
        final vault = Vault(StateStore.memory());
        final old = _credential();
        await vault.putCredential(CloudPlatform.baidu, old);
        final login = AccountLoginService(
          vault,
          (_, c) => connector.account(c),
          webAuthenticators: {CloudPlatform.baidu: connector.authenticate},
        );
        await expectLater(
          login.submitWeb(CloudPlatform.baidu, 'BDUSS=new'),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(vault.credential(CloudPlatform.baidu)!.sameAs(old), isTrue);
        expect(http.calls.map((r) => r.uri.queryParameters['clienttype']), [
          '1',
          '0',
        ]);
      },
    );

    test(
      'Login validates one file-list page and tolerates optional quota failures',
      () async {
        final http = FakeHttp((r) {
          if (r.uri.path != '/api/list' ||
              r.uri.queryParameters['clienttype'] == '1') {
            return jsonResponse({'errno': -6});
          }
          expect(r.uri.queryParameters['page'], '1');
          return jsonResponse({
            'errno': 0,
            'list': [
              for (var i = 0; i < 100; i++)
                {
                  'fs_id': '$i',
                  'path': '/$i',
                  'server_filename': '$i',
                  'size': 4,
                  'isdir': 0,
                },
            ],
          });
        });
        final connector = BaiduConnector(http);
        final result = await connector.authenticate(_credential());
        expect(result.credential.primary, _credential().primary);
        expect(result.account.nickname, '百度用户');
        expect(
          http.calls.where((r) => r.uri.path == '/api/list'),
          hasLength(2),
        );
      },
    );

    test('Malformed web listings do not pass login validation', () async {
      final connector = BaiduConnector(
        FakeHttp(
          (r) => jsonResponse(
            r.uri.queryParameters['clienttype'] == '1'
                ? {'errno': -6}
                : {'errno': 0},
          ),
        ),
      );
      await expectLater(
        connector.authenticate(_credential()),
        _message('文件列表响应不完整'),
      );
    });

    test('Cookie-only login uses the App API and reads byte quotas', () async {
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('/quota')
            ? jsonResponse({
                'errno': 0,
                'used': '1099511627776',
                'total': 2199023255552,
              })
            : jsonResponse({'errno': 0, 'netdisk_name': 'fixture'}),
      );
      final vault = Vault(StateStore.memory());
      final connector = BaiduConnector(http);
      final result = await AccountLoginService(
        vault,
        (_, c) => connector.account(c),
      ).submitWeb(CloudPlatform.baidu, 'Cookie: BDUSS=test-only');
      expect(result.account.used, 1099511627776);
      expect(result.account.total, 2199023255552);
      expect(result.account.nickname, 'fixture');
      expect(vault.credential(CloudPlatform.baidu)!.primary, 'BDUSS=test-only');
      expect(
        http.calls.every((r) => r.uri.queryParameters['app_id'] == '250528'),
        isTrue,
      );
      expect(http.calls.first.uri.host, 'pan.baidu.com');
      expect(http.calls.first.headers['User-Agent'], BaiduConnector.netdiskUa);
      expect(http.calls.last.headers['User-Agent'], BaiduConnector.netdiskUa);
      expect(http.calls.last.uri.path, '/rest/2.0/xpan/nas');
      expect(http.calls.first.uri.queryParameters['clienttype'], '1');
      expect(http.calls.first.uri.queryParameters['web'], isNull);
    });

    test(
      'Custom and legacy IDs survive web login; clearing resets to default',
      () async {
        for (final extra in [
          {'appId': '777777'},
          {'secondary': '888888'},
        ]) {
          final old = _credential(extra);
          final vault = Vault(StateStore.memory());
          await vault.putCredential(CloudPlatform.baidu, old);
          final http = FakeHttp(
            (r) => r.uri.path.endsWith('/quota')
                ? jsonResponse({'errno': 0, 'used': 0, 'total': 1024})
                : jsonResponse({
                    'errno': 0,
                    'result': {'username': 'new'},
                  }),
          );
          final connector = BaiduConnector(http);
          final login = AccountLoginService(
            vault,
            (_, c) => connector.account(c),
          );
          final saved = await login.submitWeb(CloudPlatform.baidu, 'BDUSS=new');
          expect(connector.appId(saved.credential), extra.values.single);
          expect(
            http.calls.first.uri.queryParameters['app_id'],
            extra.values.single,
          );
          http.calls.clear();
          await login.submitWeb(CloudPlatform.baidu, 'BDUSS=newer', appId: '');
          expect(http.calls.first.uri.queryParameters['app_id'], '250528');
        }
      },
    );

    test('Invalid custom ID does not save unusable credentials', () async {
      final vault = Vault(StateStore.memory()), old = _credential();
      await vault.putCredential(CloudPlatform.baidu, old);
      final http = FakeHttp();
      final connector = BaiduConnector(http);
      await expectLater(
        AccountLoginService(
          vault,
          (_, c) => connector.account(c),
        ).submitWeb(CloudPlatform.baidu, 'BDUSS=new', appId: 'not-an-id'),
        _message('应用 ID 格式无效'),
      );
      expect(vault.credential(CloudPlatform.baidu)!.sameAs(old), isTrue);
      expect(http.calls, isEmpty);
    });

    test('Unavailable nickname does not hide a valid quota', () async {
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('/quota')
            ? jsonResponse({'errno': 0, 'used': 0, 'total': 1024})
            : const HttpResult(503, 'unavailable'),
      );
      final account = await BaiduConnector(
        http,
      ).account(_credential({'nickname': 'saved-name'}));
      expect(account.nickname, 'saved-name');
      expect(account.used, 0);
      expect(account.total, 1024);
    });

    test(
      'Missing or invalid quota is an error instead of zero capacity',
      () async {
        for (final quota in <Json>[
          {'errno': 0},
          {'errno': 0, 'used': 3},
          {'errno': 0, 'used': -1, 'total': 1024},
          {'errno': 0, 'used': 0, 'total': 0},
        ]) {
          final http = FakeHttp((_) => jsonResponse(quota));
          await expectLater(
            BaiduConnector(http).account(_credential()),
            _message('容量'),
          );
          expect(http.calls.length, 1);
        }
      },
    );

    test(
      'Personal browsing does not depend on nickname or quota endpoints',
      () async {
        final http = FakeHttp((r) {
          expect(r.uri.path, '/api/list');
          return jsonResponse({'errno': 0, 'list': []});
        });
        final connector = BaiduConnector(http), c = _credential();
        final session = await connector.openPersonal(c);
        expect(http.calls, isEmpty);
        expect(await connector.list(session, '', c), isEmpty);
        expect(http.calls.single.uri.queryParameters['dir'], '/');
        expect(http.calls.single.uri.queryParameters['app_id'], '250528');
      },
    );

    test(
      'Expired Cookie responses cannot overwrite the previous account',
      () async {
        for (final response in [
          jsonResponse({'errno': -6}),
          const HttpResult(401, '<html>login required</html>'),
        ]) {
          final vault = Vault(StateStore.memory()), old = _credential();
          await vault.putCredential(CloudPlatform.baidu, old);
          final connector = BaiduConnector(FakeHttp((_) => response));
          await expectLater(
            AccountLoginService(
              vault,
              (_, c) => connector.account(c),
            ).submitWeb(CloudPlatform.baidu, 'BDUSS=expired'),
            throwsA(isA<AccountLoginRequired>()),
          );
          expect(vault.credential(CloudPlatform.baidu)!.sameAs(old), isTrue);
        }
      },
    );

    test(
      'Incomplete Cookie is rejected before any authenticated requests',
      () async {
        final http = FakeHttp(), connector = BaiduConnector(http);
        final incomplete = _credential({'primary': 'BDCLND=share-only'});
        await expectLater(
          connector.openPersonal(incomplete),
          throwsA(isA<AccountLoginRequired>()),
        );
        await expectLater(
          connector.download(_personal, _file, incomplete),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(http.calls, isEmpty);
      },
    );
  });

  group('Baidu share browsing and transfer', () {
    test(
      'App rejection retries personal browsing with the same web session',
      () async {
        final http = FakeHttp((r) {
          expect(r.headers['Cookie'], _credential().primary);
          if (r.uri.queryParameters['clienttype'] == '1') {
            return jsonResponse({'errno': -6});
          }
          expect(r.uri.queryParameters['web'], '1');
          expect(r.uri.queryParameters['start'], isNull);
          expect(r.uri.queryParameters['bdstoken'], isNull);
          expect(r.headers['User-Agent'], BaiduConnector.webUa);
          expect(r.headers['Referer'], 'https://pan.baidu.com/disk/main');
          return jsonResponse({
            'errno': 0,
            'list': [
              {
                'fs_id': '789',
                'path': _file.token,
                'server_filename': _file.name,
                'size': _file.size,
                'isdir': 0,
              },
            ],
          });
        });
        final files = await BaiduConnector(
          http,
        ).list(_personal, '/视频', _credential());
        expect(files.single.id, _file.id);
        expect(files.single.token, _file.token);
        expect(http.calls, hasLength(2));
      },
    );

    test(
      'Fallback restarts pagination instead of mixing offsets and pages',
      () async {
        final http = FakeHttp((r) {
          final app = r.uri.queryParameters['clienttype'] == '1';
          final page = app
              ? int.parse(r.uri.queryParameters['start']!) ~/ 100 + 1
              : int.parse(r.uri.queryParameters['page']!);
          if (app && page == 2) return jsonResponse({'errno': -6});
          return jsonResponse({
            'errno': 0,
            'list': [
              for (var i = (page - 1) * 100; i < (page == 1 ? 100 : 101); i++)
                {
                  'fs_id': '${app ? 'stale' : 'fresh'}-$i',
                  'path': '/$i',
                  'server_filename': '$i',
                  'isdir': 0,
                },
            ],
          });
        });
        final files = await BaiduConnector(
          http,
        ).list(_personal, '/', _credential());
        expect(files, hasLength(101));
        expect(files.every((f) => f.id.startsWith('fresh-')), isTrue);
        expect(http.calls, hasLength(4));
      },
    );

    test(
      'Transient listing errors do not trigger a second protocol request',
      () async {
        final http = FakeHttp((_) => const HttpResult(503, '{}'));
        await expectLater(
          BaiduConnector(http).list(_personal, '/', _credential()),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(1));
      },
    );

    test(
      'surl input and pass parameter reach share verification intact',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/verify')
              ? jsonResponse({'errno': 0, 'randsk': _encodedKey})
              : jsonResponse(_shareFiles()),
        );
        final link = LinkParser.parse(
          'https://pan.baidu.com/share/init?surl=Abc_Def&pass=a%2B12 提取码：b123',
        ).single;
        final session = await BaiduConnector(
          http,
        ).openShare(link, _credential());
        expect(http.calls.first.uri.queryParameters['surl'], 'Abc_Def');
        expect(_form(http.calls.first)['pwd'], 'a+12');
        expect(session.meta('shortId'), 'Abc_Def');
        expect(session.sourceLink!.url, link.url);
      },
    );

    test(
      'Encoded randsk is sent once and replaces stale BDCLND in subfolders',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/verify')
              ? jsonResponse({'errno': 0, 'randsk': _encodedKey})
              : jsonResponse(_shareFiles()),
        );
        final connector = BaiduConnector(http), c = _credential();
        final session = await connector.openShare(_link(passcode: 'a+12'), c);
        final folders = await connector.list(session, '/共享目录 + 中文', c);
        expect(_form(http.calls.first)['pwd'], 'a+12');
        final request = http.calls.last;
        expect(request.uri.queryParameters['sekey'], 'a+b/c=');
        expect(request.url, contains('sekey=a%2Bb%2Fc%3D'));
        expect(request.url, isNot(contains('%252B')));
        expect(request.headers['Cookie'], 'BDUSS=fixture; BDCLND=$_encodedKey');
        expect(request.headers['Referer'], 'https://pan.baidu.com/s/1fixture');
        expect(http.calls[1].uri.queryParameters['root'], '1');
        expect(request.uri.queryParameters['root'], '0');
        expect(request.uri.queryParameters['dir'], '/共享目录 + 中文');
        expect(folders.single.isDirectory, isTrue);
        expect(folders.single.id, '9007199254740993');
        expect(folders.single.token, '/共享目录 + 中文');
      },
    );

    test(
      'Public share omits sekey and removes credentials of a previous share',
      () async {
        final http = FakeHttp((_) => jsonResponse(_shareFiles()));
        await BaiduConnector(http).openShare(_link(), _credential());
        expect(
          http.calls.single.uri.queryParameters.containsKey('sekey'),
          isFalse,
        );
        expect(http.calls.single.headers['Cookie'], 'BDUSS=fixture');
      },
    );

    test(
      'Missing passcode and expired shares have different actionable errors',
      () async {
        for (final code in [2, -12, -9]) {
          final http = FakeHttp((_) => jsonResponse({'errno': code}));
          await expectLater(
            BaiduConnector(http).openShare(_link(), null),
            _message(code == -9 ? '失效' : '提取码'),
          );
        }
      },
    );

    test(
      'Malformed share keys do not issue list or transfer requests',
      () async {
        final http = FakeHttp(
          (_) => jsonResponse({'errno': 0, 'randsk': 'bad%'}),
        );
        await expectLater(
          BaiduConnector(http).openShare(_link(passcode: '1234'), null),
          _message('分享凭证无效'),
        );
        expect(http.calls.length, 1);
      },
    );

    test(
      'Shared folder navigation keeps the numeric ID needed for saving',
      () async {
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/nas')) {
            return jsonResponse({'errno': 0, 'uk': '999'});
          }
          if (r.uri.path.endsWith('/gettemplatevariable')) {
            return jsonResponse({
              'errno': 0,
              'result': {'bdstoken': 'token'},
            });
          }
          if (r.uri.path.endsWith('/transfer')) {
            return jsonResponse({
              'errno': 0,
              'extra': {
                'list': [
                  {'to_fs_id': '654', 'to': '/目标/目录'},
                ],
              },
            });
          }
          return jsonResponse(_shareFiles());
        });
        final vault = Vault(StateStore.memory());
        final repository = CloudRepository(
          http,
          vault,
          CleanupOutbox(vault.store, http),
        );
        final connector = BaiduConnector(http), c = _credential();
        final folder = (await connector.list(_share, '/', c)).single;
        expect(repository.directoryId(_share, folder), '/共享目录 + 中文');
        await connector.saveShare(_share, [folder], '/目标 + 文件夹', c);
        final request = http.calls.last;
        expect(jsonDecode(_form(request)['fsidlist']!), ['9007199254740993']);
        expect(_form(request)['path'], '/目标 + 文件夹');
        expect(request.uri.queryParameters['sekey'], 'a+b/c=');
        expect(request.headers['Cookie'], 'BDUSS=fixture; BDCLND=$_encodedKey');
      },
    );

    test('Legacy share sessions can recover missing share_id and uk', () async {
      final fixture = _DownloadFixture();
      final session = BrowseSession(
        platform: CloudPlatform.baidu,
        mode: BrowseMode.share,
        title: 'legacy',
        rootId: '/',
        metadata: {'shortId': 'fixture', 'sekey': _encodedKey},
      );
      await fixture.connector.saveShare(session, [_file], '/目标', _credential());
      expect(
        fixture.http.calls.any((r) => r.uri.path.endsWith('/xpan/share')),
        isTrue,
      );
      final request = fixture.http.calls.last;
      expect(request.uri.queryParameters['shareid'], '123');
      expect(request.uri.queryParameters['from'], '456');
    });

    test(
      'Personal pagination preserves folder identity and every file',
      () async {
        final http = FakeHttp((r) {
          final offset = int.parse(r.uri.queryParameters['start']!);
          final page = offset ~/ 100 + 1;
          expect(r.uri.queryParameters['limit'], '100');
          expect(r.uri.queryParameters['clienttype'], '1');
          expect(r.uri.queryParameters['channel'], '');
          return jsonResponse({
            'errno': 0,
            'list': [
              for (var i = (page - 1) * 100; i < (page == 1 ? 100 : 103); i++)
                {
                  'fs_id': i + 1,
                  'path': '/目录/$i',
                  'server_filename': '$i',
                  'isdir': i == 0 ? '1' : '0',
                },
            ],
          });
        });
        final files = await BaiduConnector(
          http,
        ).list(_personal, '/目录', _credential());
        expect(files.length, 103);
        expect(files.first.isDirectory, isTrue);
        expect(files.first.id, '1');
        expect(files.first.token, '/目录/0');
        expect(files.last.parentId, '/目录');
        expect(http.calls.length, 2);
      },
    );

    test(
      'Incomplete file-list responses are not shown as empty folders',
      () async {
        await expectLater(
          BaiduConnector(
            FakeHttp((_) => jsonResponse({'errno': 0})),
          ).list(_personal, '/', _credential()),
          _message('文件列表响应不完整'),
        );
      },
    );
  });

  group('Baidu downloads', () {
    test(
      'Web-only list session can confirm and reuse a transferred download',
      () async {
        final fixture = _DownloadFixture()..appListError = -6;
        final repo = await fixture.repository();
        final first = await repo.prepare(fixture.boundShare, _file);
        final refreshed = await repo.refresh(first);
        expect(refreshed.profile, 'baidu_preview');
        expect(fixture.transfers, 1);
        expect(fixture.lookups, hasLength(2));
        expect(fixture.listReads, 4);
        expect(fixture.lookups.first['fileId'], fixture.lookups.last['fileId']);
        expect(fixture.deleted, isEmpty);
      },
    );

    test(
      'Share lookup waits for the exact file in the personal listing',
      () async {
        final fixture = _DownloadFixture()..invisibleReads = 1;
        final spec = await fixture.connector.download(
          _share,
          _file,
          _credential(),
        );
        final saved = CloudFile.fromJson(
          spec.source!.obj('baiduTransfer').obj('file'),
        );
        expect(fixture.listReads, 2);
        expect(fixture.lookups.single['fileId'], saved.id);
        expect(fixture.lookups.single['path'], saved.token);
        expect(fixture.lookupAfterList, isTrue);
        expect(spec.fileName, _file.name);
      },
    );

    test(
      'Unconfirmed or changed transfers cannot reach the link service',
      () async {
        for (final missing in [false, true]) {
          final fixture = _DownloadFixture()
            ..invisibleReads = missing ? 3 : 0
            ..listedSize = missing ? _file.size : _file.size + 1;
          await expectLater(
            fixture.connector.download(_share, _file, _credential()),
            _message(missing ? '尚未就绪' : '信息发生变化'),
          );
          expect(fixture.lookups, isEmpty);
          expect(fixture.deleted, [fixture.created.last]);
          expect(fixture.listReads, missing ? 3 : 1);
        }
      },
    );

    test(
      'Persisted share refresh reuses its copy and keeps cleanup leased',
      () async {
        final fixture = _DownloadFixture();
        final repo = await fixture.repository();
        final first = await repo.prepare(fixture.boundShare, _file);
        final persisted = DownloadSpec.fromJson(first.toJson());
        final second = await repo.refresh(persisted);
        final third = await repo.refresh(second);
        expect(fixture.transfers, 1);
        expect(fixture.shareReads, 0);
        expect(fixture.lookups.map((v) => v['fileId']).toSet(), hasLength(1));
        expect(fixture.lookups.map((v) => v['path']).toSet(), hasLength(1));
        expect(cleanupKey(third.cleanup!), cleanupKey(first.cleanup!));
        final origin = DownloadOrigin.fromJson(third.source!);
        expect(origin.session.mode, BrowseMode.share);
        expect(origin.session.sourceLink?.url, _link().url);
        expect(origin.file.id, _file.id);
        await repo.cleanups.ready(first.cleanup);
        await repo.cleanups.drain();
        expect(fixture.deleted, isEmpty);
        for (final spec in [first, second, third]) {
          await repo.cleanups.release(spec.cleanup);
        }
        await repo.cleanups.ready(third.cleanup);
        await repo.cleanups.drain();
        expect(fixture.deleted, [fixture.created.last]);
        expect(repo.cleanups.pendingCount, 0);
      },
    );

    test('Missing temporary copy reopens the original share once', () async {
      final fixture = _DownloadFixture();
      final repo = await fixture.repository();
      final first = await repo.prepare(fixture.boundShare, _file);
      fixture.savedFiles.clear();
      fixture.listMissingCode = -9;
      final second = await repo.refresh(DownloadSpec.fromJson(first.toJson()));
      expect(fixture.transfers, 2);
      expect(fixture.shareReads, greaterThan(0));
      expect(cleanupKey(second.cleanup!), isNot(cleanupKey(first.cleanup!)));
      expect(
        fixture.lookups.first['fileId'],
        isNot(fixture.lookups.last['fileId']),
      );
      expect(DownloadOrigin.fromJson(second.source!).file.id, _file.id);
    });

    test(
      'Network and account errors during reuse never create a new copy',
      () async {
        for (final code in [-6, 2, 503]) {
          final fixture = _DownloadFixture();
          final repo = await fixture.repository();
          final first = await repo.prepare(fixture.boundShare, _file);
          if (code == 503) {
            fixture.listHttpStatus = 503;
          } else {
            fixture.listError = code;
          }
          await expectLater(repo.refresh(first), throwsA(isA<AppException>()));
          expect(fixture.transfers, 1);
          expect(fixture.lookups, hasLength(1));
          expect(fixture.shareReads, 0);
          expect(fixture.deleted, isEmpty);
        }
      },
    );

    test(
      'Older tasks without a transfer hint still restore the share',
      () async {
        final fixture = _DownloadFixture();
        final repo = await fixture.repository();
        final first = await repo.prepare(fixture.boundShare, _file);
        final legacy = first.copyWith(
          source: {...first.source!}..remove('baiduTransfer'),
        );
        final fresh = await repo.refresh(legacy);
        expect(fixture.transfers, 2);
        expect(fresh.source!['baiduTransfer'], isNotNull);
        expect(DownloadOrigin.fromJson(fresh.source!).file.id, _file.id);
      },
    );

    test(
      'Account changes during a reused lookup cannot publish its URL',
      () async {
        final fixture = _DownloadFixture();
        final repo = await fixture.repository();
        final first = await repo.prepare(fixture.boundShare, _file);
        fixture.onLookup = () => repo.vault.putCredential(
          CloudPlatform.baidu,
          Credential('changed', {'primary': 'BDUSS=new'}, updatedAt: 2),
        );
        await expectLater(repo.refresh(first), _message('帐号已变化'));
        expect(fixture.transfers, 1);
        await repo.cleanups.reconcile(recoverOrphans: true);
        await repo.cleanups.drain();
        expect(fixture.deleted, isEmpty);
      },
    );

    test(
      'Refresh stays on its owning account and rejects renewed credentials',
      () async {
        final fixture = _DownloadFixture();
        final repo = await fixture.repository();
        final first = await repo.prepare(fixture.boundShare, _file);
        final vault = repo.vault as Vault;
        final owner = vault.activeAccountId(CloudPlatform.baidu)!;
        final other = await vault.createAccount(CloudPlatform.baidu);
        await vault.withAccount(
          CloudPlatform.baidu,
          other,
          () => repo.vault.putCredential(
            CloudPlatform.baidu,
            _credential({'primary': 'BDUSS=other'}),
          ),
        );
        await vault.activate(CloudPlatform.baidu, other);
        await repo.refresh(first);
        expect(fixture.lookups.last['cookie'], contains('BDUSS=fixture'));
        expect(vault.activeAccountId(CloudPlatform.baidu), other);
        await vault.withAccount(
          CloudPlatform.baidu,
          owner,
          () => repo.vault.putCredential(
            CloudPlatform.baidu,
            Credential('changed', {'primary': 'BDUSS=new'}, updatedAt: 2),
          ),
        );
        await expectLater(repo.refresh(first), throwsA(isA<AppException>()));
        expect(fixture.lookups, hasLength(2));
        expect(fixture.transfers, 1);
      },
    );

    test(
      'Cancellation after reusing a copy keeps existing cleanup protected',
      () async {
        final fixture = _DownloadFixture();
        final repo = await fixture.repository();
        final first = await repo.prepare(fixture.boundShare, _file);
        final scope = RequestScope();
        fixture.onLookup = () async => scope.cancel();
        await expectLater(
          scope.run(() => repo.refresh(first)),
          _message('请求已取消'),
        );
        await repo.cleanups.reconcile(recoverOrphans: true);
        await repo.cleanups.drain();
        expect(fixture.deleted, isEmpty);
        expect(fixture.transfers, 1);
      },
    );

    test(
      'Malformed persisted transfer cannot reuse an unrelated cleanup',
      () async {
        final fixture = _DownloadFixture();
        final first = await fixture.connector.download(
          _share,
          _file,
          _credential(),
        );
        final altered = first.copyWith(
          cleanup: const DownloadCleanup(
            url: 'https://pan.baidu.com/api/filemanager?opera=delete',
            body: 'filelist=%5B%22%2Funrelated%22%5D',
          ),
        );
        expect(
          await fixture.connector.refreshTransfer(altered, _credential()),
          isNull,
        );
        expect(fixture.lookups, hasLength(1));
      },
    );

    test(
      'Owner shares download the original and save by copy without transfer',
      () async {
        final fixture = _DownloadFixture()..accountUk = '456';
        final spec = await fixture.connector.download(
          _share,
          _file,
          _credential(),
        );
        expect(spec.url, 'https://example.com/plain');
        expect(spec.cleanup, isNull);
        expect(fixture.created, isEmpty);
        expect(
          fixture.http.calls.any((r) => r.uri.path.endsWith('/transfer')),
          isFalse,
        );
        await fixture.connector.saveShare(
          _share,
          [_file],
          '/目标',
          _credential(),
        );
        final copy = fixture.http.calls.last;
        expect(copy.uri.queryParameters['opera'], 'copy');
        expect(jsonDecode(_form(copy)['filelist']!), [
          {'path': _file.token, 'dest': '/目标', 'newname': _file.name},
        ]);
      },
    );
    test('Each lookup receives the current account, file and device', () async {
      final fixture = _DownloadFixture();
      final first = await fixture.connector.download(
        _personal,
        _file,
        _credential(),
      );
      final second = await fixture.connector.download(
        _personal,
        _file,
        _credential({'primary': 'BDUSS=other-account', 'appId': '777777'}),
      );
      expect(fixture.lookups, hasLength(2));
      expect(fixture.lookups.first['cookie'], contains('BDUSS=fixture'));
      expect(fixture.lookups.last['cookie'], 'BDUSS=other-account');
      expect(fixture.lookups.last['appId'], '777777');
      expect(fixture.lookups.last['path'], _file.token);
      expect(fixture.lookups.last['fileId'], _file.id);
      expect(
        asJson(fixture.lookups.last['device'])['id'],
        asJson(fixture.lookups.first['device'])['id'],
      );
      expect(first.fileName, _file.name);
      expect(first.expectedSize, _file.size);
      expect(first.profile, 'baidu_preview');
      expect(second.headers['Cookie'], 'BDUSS=other-account');
      expect(fixture.http.calls, isEmpty);
    });

    test(
      'Account direct delivery uses service headers without sending the account to CDN',
      () async {
        final fixture = _DownloadFixture()
          ..resolvedLink = const BaiduResolvedLink(
            url: 'https://fixture.baidupcs.com/file',
            profile: 'baidu_direct',
            headers: {
              'host': 'fixture.baidu-int.com',
              'user-agent': 'netdisk',
              'accept-encoding': 'identity',
            },
          );
        final spec = await fixture.connector.download(
          _personal,
          _file,
          _credential(),
        );
        expect(spec.profile, 'baidu_direct');
        expect(spec.headers['host'], 'fixture.baidu-int.com');
        expect(spec.headers.containsKey('Cookie'), isFalse);
        expect(spec.headers.containsKey('cookie'), isFalse);
        expect(spec.headers.containsKey('Referer'), isFalse);
      },
    );

    test(
      'Legacy files forward their file ID when the path is unavailable',
      () async {
        final fixture = _DownloadFixture();
        await fixture.connector.download(
          _personal,
          const CloudFile(id: '789', name: 'legacy.bin'),
          _credential(),
        );
        expect(fixture.lookups.single['fileId'], '789');
        expect(fixture.lookups.single['path'], '');
      },
    );

    test(
      'Service errors propagate and clean only this share temporary folder',
      () async {
        final fixture = _DownloadFixture()
          ..lookupError = const AccountLoginRequired('expired');
        await expectLater(
          fixture.connector.download(_share, _file, _credential()),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(fixture.lookups, hasLength(1));
        expect(fixture.deleted.single, fixture.created.last);
        expect(fixture.deleted.single, startsWith('/文析助手临时转存/tr_'));
      },
    );

    test(
      'Cancellation after service resolution cannot publish a stale URL',
      () async {
        final scope = RequestScope();
        final connector = BaiduConnector(
          FakeHttp(),
          linkLookup:
              ({
                required cookie,
                required path,
                required fileId,
                required appId,
                required device,
              }) async {
                scope.cancel();
                return const BaiduResolvedLink(
                  url: 'https://fixture.baidupcs.com/file',
                  preview: true,
                );
              },
        );
        await expectLater(
          scope.run(() => connector.download(_personal, _file, _credential())),
          _message('请求已取消'),
        );
      },
    );

    test(
      'Share resolution retains each unique temporary folder until cleanup',
      () async {
        final fixture = _DownloadFixture();
        final first = await fixture.connector.download(
          _share,
          _file,
          _credential(),
        );
        final second = await fixture.connector.download(
          _share,
          _file,
          _credential(),
        );
        expect(fixture.deleted, isEmpty);
        expect(fixture.staged.length, 2);
        final a =
            jsonDecode(Uri.splitQueryString(first.cleanup!.body!)['filelist']!)
                as List;
        final b =
            jsonDecode(Uri.splitQueryString(second.cleanup!.body!)['filelist']!)
                as List;
        expect(a.single, startsWith('/文析助手临时转存/tr_'));
        expect(b.single, isNot(a.single));
        expect(fixture.created, containsAll([a.single, b.single]));
        expect(fixture.tokenRequests, 0);
        expect(Uri.parse(first.cleanup!.url).queryParameters['newVerify'], '1');
        expect(
          fixture.http.calls
              .where((r) => r.uri.path.endsWith('/transfer'))
              .every(
                (r) =>
                    r.uri.queryParameters['bdstoken'] ==
                    '4cf9d4f0069fc18fb3fcc0a50dceb852',
              ),
          isTrue,
        );
      },
    );

    test(
      'Failed share transfer only cleans the folder created for that request',
      () async {
        final fixture = _DownloadFixture()..transferError = true;
        await expectLater(
          fixture.connector.download(_share, _file, _credential()),
          _message('fixture transfer failed'),
        );
        expect(fixture.deleted.single, fixture.created.last);
        expect(fixture.deleted, isNot(contains('/文析助手临时转存')));
        expect(fixture.staged.length, 1);
      },
    );

    test('Cleanup staging failure cleans its folder before stopping', () async {
      final fixture = _DownloadFixture()..stageError = true;
      await expectLater(
        fixture.connector.download(_share, _file, _credential()),
        _message('fixture storage failed'),
      );
      expect(fixture.deleted.single, fixture.created.last);
      expect(
        fixture.http.calls.any((r) => r.uri.path.endsWith('/transfer')),
        isFalse,
      );
    });

    test(
      'Unexpected transfer paths cannot be used to resolve another file',
      () async {
        final fixture = _DownloadFixture()
          ..transferredPath = '/existing-user-file.bin';
        await expectLater(
          fixture.connector.download(_share, _file, _credential()),
          _message('百度转存未返回完整文件路径'),
        );
        expect(fixture.deleted.single, fixture.created.last);
        expect(fixture.lookups, isEmpty);
      },
    );
  });

  group('Baidu file operations', () {
    test(
      'App file operations confirm completion and escape full paths',
      () async {
        final fixture = _DownloadFixture(), c = _credential();
        const file = CloudFile(
          id: '123',
          name: '引号" + &.txt',
          token: '/资料/引号" + &.txt',
        );
        await fixture.connector.rename(_personal, file, '新的"文件 + &.txt', c);
        final rename = fixture.http.calls.last;
        expect(rename.uri.host, 'pan.baidu.com');
        expect(rename.uri.queryParameters['async'], '0');
        expect(jsonDecode(_form(rename)['filelist']!), [
          {'path': file.token, 'newname': '新的"文件 + &.txt'},
        ]);
        await fixture.connector.move(_personal, [file], '/目标 + &', c);
        final move = fixture.http.calls.last;
        expect(move.uri.host, 'pan.baidu.com');
        expect(move.uri.queryParameters['async'], '0');
        expect(jsonDecode(_form(move)['filelist']!), [
          {'path': file.token, 'dest': '/目标 + &', 'newname': file.name},
        ]);
        await fixture.connector.delete(_personal, [file], c);
        final delete = fixture.http.calls.last;
        expect(delete.uri.host, 'pan.baidu.com');
        expect(delete.uri.queryParameters['newVerify'], '1');
        expect(delete.uri.queryParameters['async'], '0');
        expect(jsonDecode(_form(delete)['filelist']!), [file.token]);
      },
    );

    test(
      'Batch file errors are reported even when the envelope says success',
      () async {
        final fixture = _DownloadFixture()
          ..managerResult = {
            'errno': 0,
            'info': [
              {'errno': -9, 'errmsg': 'fixture file missing'},
            ],
          };
        await expectLater(
          fixture.connector.delete(_personal, [_file], _credential()),
          _message('fixture file missing'),
        );
      },
    );

    test(
      'App shares use path_list while folders retain numeric fs_id',
      () async {
        final fixture = _DownloadFixture(), c = _credential();
        final folder = await fixture.connector.createFolder(
          _personal,
          '/',
          '新目录',
          c,
        );
        expect(folder.id, '678');
        expect(folder.token, '/新目录');
        expect(fixture.http.calls.single.uri.queryParameters['norename'], '');
        final share = await fixture.connector.createShare(
          _personal,
          [folder],
          const ShareOptions('fixture', expiryDays: 7, passcode: 'a123'),
          c,
        );
        final body = _form(fixture.http.calls.last);
        expect(fixture.http.calls.last.uri.path, '/share/pset');
        expect(jsonDecode(body['path_list']!), ['/新目录']);
        expect(body['period'], '7');
        expect(body['pwd'], 'a123');
        expect(share.url, 'https://pan.baidu.com/s/1fixture');
        expect(share.passcode, 'a123');
      },
    );

    test(
      'Existing user folders are not falsely reported as newly created',
      () async {
        final fixture = _DownloadFixture()..createError = -8;
        await expectLater(
          fixture.connector.createFolder(_personal, '/', '已有目录', _credential()),
          throwsA(isA<AppException>()),
        );
      },
    );
  });
}

class _DownloadFixture {
  _DownloadFixture() {
    http = FakeHttp(_respond);
    connector = BaiduConnector(
      http,
      linkLookup: lookup,
      stageCleanup: (cleanup) async {
        if (stageError) throw const AppException('fixture storage failed');
        staged.add(cleanup);
      },
    );
  }
  late final FakeHttp http;
  late final BaiduConnector connector;
  final lookups = <Json>[];
  Future<void> Function()? onLookup;
  bool lookupAfterList = false;
  int invisibleReads = 0, listReads = 0, transfers = 0, shareReads = 0;
  int listedSize = _file.size;
  int? listError, listMissingCode, appListError;
  int listHttpStatus = 200;
  final savedFiles = <String, Json>{};
  Object? lookupError;
  BaiduResolvedLink? resolvedLink;
  Json managerResult = {'errno': 0};
  String accountUk = '999';
  bool transferError = false, stageError = false;
  String? transferredPath;
  int? createError;
  int tokenRequests = 0;
  final created = <String>[], deleted = <String>[];
  final staged = <DownloadCleanup>[];

  Future<BaiduResolvedLink> lookup({
    required String cookie,
    required String path,
    required String fileId,
    required String appId,
    required Json device,
  }) async {
    lookups.add({
      'cookie': cookie,
      'path': path,
      'fileId': fileId,
      'appId': appId,
      'device': device,
    });
    lookupAfterList = http.calls.lastOrNull?.uri.path == '/api/list';
    await onLookup?.call();
    if (lookupError != null) throw lookupError!;
    return resolvedLink ??
        const BaiduResolvedLink(
          url: 'https://example.com/plain',
          preview: true,
        );
  }

  BrowseSession get boundShare => BrowseSession.fromJson({
    ..._share.toJson(),
    'sourceLink': _link().toJson(),
  });

  Future<CloudRepository> repository() async {
    final vault = Vault(StateStore.memory());
    await vault.putCredential(CloudPlatform.baidu, _credential());
    final repo = CloudRepository(
      http,
      vault,
      CleanupOutbox(vault.store, http),
      preparationRetries: () => 0,
    );
    repo.connectors[CloudPlatform.baidu] = BaiduConnector(
      repo.http,
      store: vault,
      linkLookup: lookup,
      stageCleanup:
          (repo.connector(CloudPlatform.baidu) as BaiduConnector).stageCleanup,
    );
    return repo;
  }

  HttpResult _respond(RecordedRequest r) {
    switch (r.uri.path) {
      case '/rest/2.0/xpan/nas':
        return jsonResponse({'errno': 0, 'uk': accountUk});
      case '/api/gettemplatevariable':
        tokenRequests++;
        return jsonResponse({
          'errno': 0,
          'result': {'bdstoken': 'token'},
        });
      case '/api/create':
        final path = _form(r)['path']!;
        created.add(path);
        return jsonResponse({
          'errno': createError ?? (path == '/文析助手临时转存' ? -8 : 0),
          'fs_id': 678,
          'path': path,
        });
      case '/share/transfer':
        if (transferError) {
          return jsonResponse({
            'errno': 2,
            'errmsg': 'fixture transfer failed',
          });
        }
        final directory = _form(r)['path']!;
        final targetId = '${654 + transfers++}';
        final targetPath = transferredPath ?? '$directory/${_file.name}';
        savedFiles[directory] = {
          'fs_id': targetId,
          'path': targetPath,
          'server_filename': _file.name,
          'size': listedSize,
          'isdir': 0,
        };
        return jsonResponse({
          'errno': 0,
          'extra': {
            'list': [
              {'to_fs_id': targetId, 'to': targetPath},
            ],
          },
        });
      case '/api/list':
        listReads++;
        if (appListError != null &&
            r.uri.queryParameters['clienttype'] == '1') {
          return jsonResponse({'errno': appListError});
        }
        if (listHttpStatus != 200) return HttpResult(listHttpStatus, '{}');
        if (listError != null) return jsonResponse({'errno': listError});
        final saved = savedFiles[r.uri.queryParameters['dir']];
        if (saved == null && listMissingCode != null) {
          return jsonResponse({'errno': listMissingCode});
        }
        return jsonResponse({
          'errno': 0,
          'list': [if (saved != null && listReads > invisibleReads) saved],
        });
      case '/api/filemanager':
        if (r.uri.queryParameters['opera'] == 'delete') {
          deleted.addAll(
            (jsonDecode(_form(r)['filelist']!) as List).cast<String>(),
          );
        }
        return jsonResponse(managerResult);
      case '/rest/2.0/xpan/share':
        shareReads++;
        return jsonResponse({
          ..._shareFiles(),
          'list': [
            {
              'fs_id': _file.id,
              'path': _file.token,
              'server_filename': _file.name,
              'size': _file.size,
              'isdir': 0,
            },
          ],
        });
      case '/share/pset':
        return jsonResponse({
          'errno': 0,
          'shorturl': 'https://pan.baidu.com/s/1fixture',
        });
      default:
        throw StateError('Unexpected fixture endpoint: ${r.uri.path}');
    }
  }
}
