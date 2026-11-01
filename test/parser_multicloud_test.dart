import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/data/providers/baidu_public_parser.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/public_share_route.dart';
import 'package:asterlink/domain/settings.dart';
import 'support.dart';

final _root = Directory('test/fixtures/parser_rules');
Json _json(String name) =>
    asJson(jsonDecode(File('${_root.path}/$name.json').readAsStringSync()));
final _publicKey = File('${_root.path}/public-key-v3.txt').readAsStringSync();
final _now = DateTime.fromMillisecondsSinceEpoch(1791936000000);
Matcher _code(String code) =>
    isA<ParserRuleError>().having((e) => e.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('PHP v3 presets and signed multi-drive backup verify in Dart', () {
    final presets = _json('presets-v3');
    expect(presets, hasLength(12));
    for (final item in presets.values) {
      ParserRule.fromJson(asJson(item));
    }
    final bundle = ParserBundle.verify(
      _json('bundle-multicloud'),
      _publicKey,
      now: _now,
    );
    expect(
      bundle.sites.where((s) => s.rule.platform == CloudPlatform.quark),
      hasLength(2),
    );
    final backup = _json('backup-multicloud');
    final legacy = ParserBundle.verify(
      backup.obj('bundle'),
      _publicKey,
      now: _now,
    );
    expect(
      legacy.sites.every((s) => s.rule.platform == CloudPlatform.baidu),
      isTrue,
    );
    final latest = ParserBundle.verifyBackup(
      backup,
      _publicKey,
      now: _now.add(const Duration(days: 30)),
    );
    expect(latest.id, bundle.id);
    expect(latest.sites, hasLength(12));
    backup['engines']['3']['bundle']['signature'] =
        backup['bundle']['signature'];
    expect(
      () => ParserBundle.verifyBackup(backup, _publicKey, now: _now),
      throwsA(_code('RULE_BACKUP_SIGNATURE')),
    );
  });
  test(
    'Signed platform switches survive static export and reject non-boolean values',
    () {
      final current = ParserBundle.verify(
        _json('bundle-platforms-closed'),
        _publicKey,
        now: _now,
      );
      expect(current.publicParsing[CloudPlatform.baidu], isFalse);
      expect(current.publicParsing[CloudPlatform.uc], isFalse);
      expect(current.publicParsing[CloudPlatform.c139], isTrue);
      final backup = ParserBundle.verifyBackup(
        _json('backup-platforms-closed'),
        _publicKey,
        now: _now.add(const Duration(days: 30)),
      );
      expect(backup.publicParsing, current.publicParsing);
      expect(
        () => ParserBundle.verify(
          _json('bundle-platforms-invalid'),
          _publicKey,
          now: _now,
        ),
        throwsA(_code('RULE_SIGNATURE')),
      );
    },
  );
  test(
    'Download Cookie merge uses the actual host and bounded header values',
    () {
      expect(
        RuleExpression.hostMatches(
          'https://a.drive.quark.cn/file',
          'drive.quark.cn',
        ),
        isTrue,
      );
      expect(
        RuleExpression.hostMatches(
          'https://drive.quark.cn.attacker.com/',
          'drive.quark.cn',
        ),
        isFalse,
      );
      expect(
        RuleExpression.hostMatches(
          'https://a.pds.quark.cn/file?next=https://drive.quark.cn/',
          'drive.quark.cn',
        ),
        isFalse,
      );
      expect(
        RuleExpression.mergeCookies(
          'UID=account; Video-Auth=old',
          'UID=sender; Video-Auth=new; __sdid=valid',
          ['video-auth'],
        ),
        'UID=account; Video-Auth=new; __sdid=valid',
      );
      expect(
        () => RuleExpression.mergeCookies('UID=ok', 'x=a\r\nHost: bad', []),
        throwsA(_code('RULE_HEADER')),
      );
      final rule = ParserRule.fromJson(
        _json('presets-v3').obj('panapidown_uc'),
      );
      expect(
        () => rule.validateResult(
          'download',
          {
            'fs_id': 'f',
            'urls': ['https://cdn.uc.cn/file'],
            'headers': {'Authorization': 'secret'},
          },
          {
            'file': {'fs_id': 'f'},
          },
        ),
        throwsA(_code('RULE_HEADER')),
      );
      final old = _json('presets-v3').obj('panapidown_baidu')..['engine'] = 1;
      old.remove('passwordStage');
      old['operations']['list']['result']['state'] = {
        r'$op': 'cookieMerge',
        'args': ['', '', []],
      };
      expect(() => ParserRule.fromJson(old), throwsA(_code('INVALID_RULE')));
    },
  );

  group('multi-drive routes', () {
    late Directory directory;
    late StateStore state;
    late Vault vault;
    late ParserRuleHub hub;
    late FakeHttp http;
    late DateTime now;
    late Map<String, int> listings;
    late bool fileChanged;
    late bool manualPassword;
    late String? policyManifest;

    setUp(() async {
      now = _now;
      directory = await Directory.systemTemp.createTemp('parser-multicloud-');
      state = StateStore.memory();
      vault = Vault(state);
      listings = {};
      fileChanged = false;
      manualPassword = false;
      policyManifest = null;
      http = FakeHttp((r) {
        if (r.uri.host == 'hub.example.com') {
          expect(r.headers['X-Parser-Engine'], '${ParserRule.engine}');
          if (r.uri.path == '/v1/rules') {
            return jsonResponse({
              'ok': true,
              'data': _json(
                policyManifest ??
                    (manualPassword
                        ? 'bundle-multicloud-manual'
                        : 'bundle-multicloud'),
              ),
            });
          }
          if (r.uri.path.endsWith('/password')) {
            final id = r.uri.pathSegments[2];
            return jsonResponse({
              'ok': true,
              'data': {
                'password': '$id-password',
                'version': 1,
                'cacheFor': 300,
              },
            });
          }
          throw StateError('Unexpected hub request ${r.uri.path}');
        }
        expect(r.uri.host, 'pdpb.cn');
        expect(r.headers.containsKey('Cookie'), isFalse);
        expect(r.headers.containsKey('Authorization'), isFalse);
        final provider = r.uri.pathSegments[1];
        final body = r.json;
        if (r.uri.path.endsWith('/fetch')) {
          expect(
            body[provider == 'uc' ? 'parse_password_input' : 'parse_password'],
            'panapidown_$provider-password',
          );
          expect(body['fid'], 'file-id');
          expect(body['stoken'], 'share-${listings[provider]}');
          expect(body['fid_token'], 'file-${listings[provider]}');
          expect(body['pdir_fid'], 'folder-id');
          return jsonResponse({
            'ok': true,
            'result': {
              'download_url':
                  'https://cdn.${provider == 'uc' ? 'uc.cn' : 'drive.quark.cn'}/file',
              'uc_sender_cookie': 'uc=server-cookie',
              'quark_account_cookie': 'UID=account; Video-Auth=old',
              'quark_sender_cookie': 'UID=sender; Video-Auth=current',
            },
          });
        }
        final detail = r.uri.path.endsWith('/detail');
        if (!detail) listings[provider] = (listings[provider] ?? 0) + 1;
        final n = listings[provider]!;
        if (detail) {
          expect(body['stoken'], 'share-$n');
          expect(body['pdir_fid'], 'folder-id');
        }
        final files = [
          if (detail)
            {
              'fid': 'file-id',
              'file_name': fileChanged ? 'changed.bin' : 'file.bin',
              'size': 12,
              'dir': false,
              'share_fid_token': 'file-$n',
            }
          else
            {'fid': 'folder-id', 'file_name': 'folder', 'size': 0, 'dir': true},
        ];
        return jsonResponse({
          'ok': true,
          'result': provider == 'uc'
              ? {
                  'uc': {
                    'data': {
                      'token_info': {'stoken': 'share-$n'},
                      'detail_info': {'list': files},
                    },
                  },
                }
              : {'stoken': 'share-$n', 'files': files},
        });
      });
      hub = ParserRuleHub(
        store: vault,
        directory: directory,
        http: http,
        url: 'https://hub.example.com',
        apiKey: 'fixture-key',
        publicKey: _publicKey,
        clock: () => now,
      );
      expect(await hub.refresh(force: true), isTrue);
    });
    tearDown(() async {
      await hub.close();
      await directory.delete(recursive: true);
    });

    test(
      'Selection and route preference persist separately for each drive',
      () async {
        expect(hub.publicPreferred(CloudPlatform.baidu), isFalse);
        expect(hub.publicPreferred(CloudPlatform.uc), isFalse);
        expect(hub.publicPreferred(CloudPlatform.quark), isFalse);
        await hub.select('panapidown_uc');
        await hub.select('mdx_quark');
        await hub.preferPublic(CloudPlatform.baidu, true);
        await hub.preferPublic(CloudPlatform.uc, true);
        final restarted = ParserRuleHub(
          store: vault,
          directory: directory,
          http: http,
          url: 'https://hub.example.com',
          apiKey: 'fixture-key',
          publicKey: _publicKey,
          clock: () => now,
        );
        try {
          expect(restarted.selectedFor(CloudPlatform.uc), 'panapidown_uc');
          expect(restarted.selectedFor(CloudPlatform.quark), 'mdx_quark');
          expect(restarted.selectedFor(CloudPlatform.baidu), 'mf_dg22');
          expect(restarted.publicPreferred(CloudPlatform.uc), isTrue);
          expect(restarted.publicPreferred(CloudPlatform.quark), isFalse);
          expect(restarted.publicPreferred(CloudPlatform.baidu), isTrue);
          await restarted.preferPublic(CloudPlatform.baidu, false);
          expect(hub.publicPreferred(CloudPlatform.baidu), isFalse);
          final site = await restarted.forNewShare(platform: CloudPlatform.uc);
          expect(site?.rule.platform, CloudPlatform.uc);
          await expectLater(
            restarted.forNewShare(
              platform: CloudPlatform.uc,
              siteId: 'mdx_quark',
            ),
            throwsA(_code('RULE_UNAVAILABLE')),
          );
        } finally {
          await restarted.close();
        }
      },
    );

    test(
      'UC and Quark browse without passwords then download with isolated passwords and one device ID',
      () async {
        final provider = BaiduPublicParser(
          http,
          store: vault,
          hub: hub,
          clock: () => now,
        );
        final requests = <String>[];
        for (final platform in [CloudPlatform.uc, CloudPlatform.quark]) {
          final link = LinkParser.parse(
            'https://${platform == CloudPlatform.uc ? 'drive.uc.cn' : 'pan.quark.cn'}/s/abcdef',
          ).single;
          final session = await provider.openShare(
            link,
            parserSiteId: 'panapidown_${platform.name}',
          );
          expect(session.platform, platform);
          expect(PublicShareRoute.uses(session), isTrue);
          final root = await provider.list(session, '/');
          expect(root.single.isDirectory, isTrue);
          final files = await provider.list(session, root.single.id);
          expect(
            http.calls.where(
              (r) =>
                  r.uri.path ==
                  '/v1/sites/panapidown_${platform.name}/password',
            ),
            isEmpty,
          );
          final spec = await provider.download(session, files.single);
          requests.addAll(
            http.calls
                .where((r) => r.uri.host == 'pdpb.cn')
                .map((r) => r.headers['X-Device-Id']!),
          );
          expect(spec.profile, '${platform.name}_public');
          expect(
            spec.headers['Cookie'],
            platform == CloudPlatform.uc
                ? 'uc=server-cookie'
                : 'UID=account; Video-Auth=current',
          );
          expect(
            const AppSettings().connectionsFor(platform, spec.profile),
            greaterThan(1),
          );
          expect(jsonEncode(session.toJson()), isNot(contains('file-2')));
        }
        expect(requests.toSet(), hasLength(1));
      },
    );

    test(
      'Download-stage passwords still honor disabled automatic filling before browsing',
      () async {
        await hub.password('panapidown_uc');
        manualPassword = true;
        expect(await hub.refresh(force: true), isTrue);
        final site = hub.currentSite('panapidown_uc')!;
        expect(site.passwordPrompt.autoFill, isFalse);
        expect(site.rule.requiresPasswordFor('list'), isFalse);
        final provider = BaiduPublicParser(
          http,
          store: vault,
          hub: hub,
          clock: () => now,
        );
        try {
          await expectLater(
            provider.openShare(
              LinkParser.parse('https://drive.uc.cn/s/abcdef').single,
              parserSiteId: site.id,
            ),
            throwsA(isA<ParserPasswordRequired>()),
          );
          expect(http.calls.where((r) => r.uri.host == 'pdpb.cn'), isEmpty);
          expect(
            http.calls.where((r) => r.uri.path.endsWith('/password')),
            hasLength(1),
          );
        } finally {
          await provider.passwords.close();
        }
      },
    );

    test(
      'Closed drives block cached shares, restored tasks and Baidu built-in fallback until reopened',
      () async {
        final provider = BaiduPublicParser(
          http,
          store: vault,
          hub: hub,
          clock: () => now,
        );
        final session = await provider.openShare(
          LinkParser.parse('https://drive.uc.cn/s/abcdef').single,
          parserSiteId: 'panapidown_uc',
        );
        final files = await provider.list(session, 'folder-id');
        await provider.download(session, files.single);
        await hub.select('panapidown_uc');
        await hub.preferPublic(CloudPlatform.uc, true);
        policyManifest = 'bundle-platforms-closed';
        expect(await hub.refresh(force: true), isTrue);
        final calls = http.calls.length;
        expect(hub.sitesFor(CloudPlatform.uc), isEmpty);
        expect(hub.sitesFor(CloudPlatform.quark), isEmpty);
        expect(hub.sitesFor(CloudPlatform.c139), isNotEmpty);
        await expectLater(
          hub.forNewShare(),
          throwsA(_code('PUBLIC_PARSING_CLOSED')),
        );
        await expectLater(
          provider.list(session, '/'),
          throwsA(_code('PUBLIC_PARSING_CLOSED')),
        );
        await expectLater(
          provider.ensurePassword(session),
          throwsA(_code('PUBLIC_PARSING_CLOSED')),
        );
        await expectLater(
          provider.download(session, files.single),
          throwsA(_code('PUBLIC_PARSING_CLOSED')),
        );
        expect(http.calls.length, calls);
        final restarted = ParserRuleHub(
          store: vault,
          directory: directory,
          http: http,
          url: hub.url,
          apiKey: hub.apiKey,
          publicKey: _publicKey,
          clock: () => now,
        );
        try {
          final restored = BaiduPublicParser(
            http,
            store: vault,
            hub: restarted,
            clock: () => now,
          );
          await expectLater(
            restored.download(
              BrowseSession.fromJson(session.toJson()),
              files.single,
            ),
            throwsA(_code('PUBLIC_PARSING_CLOSED')),
          );
          expect(http.calls.length, calls);
          expect(restarted.publicParsingAllowed(CloudPlatform.baidu), isFalse);
        } finally {
          await restarted.close();
        }
        policyManifest = 'bundle-platforms-reopened';
        expect(await hub.refresh(force: true), isTrue);
        expect(hub.selectedFor(CloudPlatform.uc), 'panapidown_uc');
        expect(hub.publicPreferred(CloudPlatform.uc), isTrue);
        expect(
          (await provider.download(session, files.single)).url,
          'https://cdn.uc.cn/file',
        );
        await provider.passwords.close();
      },
    );
    test(
      'Expired and restored tasks reload file tokens and reject replaced files',
      () async {
        final provider = BaiduPublicParser(
          http,
          store: vault,
          hub: hub,
          clock: () => now,
        );
        final link = LinkParser.parse('https://drive.uc.cn/s/abcdef').single;
        final session = await provider.openShare(
          link,
          parserSiteId: 'panapidown_uc',
        );
        await provider.list(session, '/');
        final files = await provider.list(session, 'folder-id');
        await provider.download(session, files.single);
        now = now.add(const Duration(minutes: 6));
        await provider.download(session, files.single);
        expect(listings['uc'], 3);
        final restored = BaiduPublicParser(
          http,
          store: vault,
          hub: hub,
          clock: () => now,
        );
        await restored.download(
          BrowseSession.fromJson(session.toJson()),
          files.single,
        );
        expect(listings['uc'], 4);
        now = now.add(const Duration(minutes: 6));
        fileChanged = true;
        final before = http.calls
            .where((r) => r.uri.path.endsWith('/fetch'))
            .length;
        await expectLater(
          restored.download(session, files.single),
          throwsA(isA<AppException>()),
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/fetch')),
          hasLength(before),
        );
      },
    );

    test(
      'Repository dispatches non-Baidu public shares without account login',
      () async {
        final cleanups = CleanupOutbox(state, http);
        final repository = CloudRepository(
          http,
          vault,
          cleanups,
          parserHub: hub,
        );
        final link = LinkParser.parse('https://drive.uc.cn/s/abcdef').single;
        final session = await repository.share(
          link,
          parserSiteId: 'panapidown_uc',
        );
        final root = await repository.list(session, session.rootId);
        final files = await repository.list(
          session,
          repository.directoryId(session, root.single),
        );
        final plan = repository.planDownload(session, files.single);
        expect(plan.profile, 'uc_public');
        final download = await repository.prepare(session, files.single);
        expect(download.url, 'https://cdn.uc.cn/file');
        expect(vault.credential(CloudPlatform.uc), isNull);
      },
    );
  });
}
