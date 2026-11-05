import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/data/parser_rules/codecs.dart';
import 'package:asterlink/data/parser_rules/engine.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/providers/baidu_public_parser.dart';
import 'package:asterlink/data/providers/baidu_public_password.dart';
import 'baidu_public_parser_support.dart';
import 'support.dart';

final _fixtures = Directory('test/fixtures/parser_rules');
Json _json(String name) =>
    asJson(jsonDecode(File('${_fixtures.path}/$name.json').readAsStringSync()));
final _publicKey = File('${_fixtures.path}/public-key.txt').readAsStringSync();
final _now = DateTime.fromMillisecondsSinceEpoch(1791936000000);
final _input = <String, dynamic>{
  'url': BaiduPublicFixture.url,
  'surl': '1PublicFixture',
  'pwd': 'a1b2',
  'dir': '/',
  'file': {
    'fs_id': BaiduPublicFixture.fileId,
    'server_filename': BaiduPublicFixture.name,
    'size': 4,
  },
  'state': {'uk': '456', 'shareid': '123', 'randsk': 'a%2Bb%2Fc%3D'},
};
Matcher _code(String code) =>
    isA<ParserRuleError>().having((e) => e.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Json presets;
  setUp(() => presets = _json('presets'));

  test('All direct backend presets validate in the App', () {
    expect(presets.length, 5);
    for (final item in presets.values) {
      expect(ParserRule.fromJson(asJson(item)).allowedHosts, isNotEmpty);
    }
  });
  test(
    'App verifies a real PHP RSA signature and refuses modified payload',
    () {
      final envelope = _json('bundle-1');
      final bundle = ParserBundle.verify(envelope, _publicKey, now: _now);
      expect(bundle.sites.single.rule.siteId, 'mf_dg22');
      final bytes = base64Decode(envelope.str('payload'))..[100] ^= 1;
      expect(
        () => ParserBundle.verify(
          {...envelope, 'payload': base64Encode(bytes)},
          _publicKey,
          now: _now,
        ),
        throwsA(_code('RULE_SIGNATURE')),
      );
      expect(
        () => ParserBundle.verify(
          {...envelope, 'keyId': '0000000000000000'},
          _publicKey,
          now: _now,
        ),
        throwsA(_code('RULE_SIGNATURE')),
      );
      expect(
        () => ParserBundle.verify(
          envelope,
          _publicKey,
          now: _now.add(const Duration(days: 8)),
        ),
        throwsA(_code('RULE_SIGNATURE')),
      );
      expect(
        ParserBundle.verify(
          envelope,
          _publicKey,
          now: _now.add(const Duration(days: 8)),
          archived: true,
        ).revision,
        1,
      );
    },
  );
  test(
    'Unsupported code execution, account references and headers are rejected',
    () {
      for (final expr in [
        {
          r'$op': 'eval',
          'args': ['anything'],
        },
        {r'$ref': 'accounts.baidu.cookie'},
      ]) {
        final rule = asJson(jsonDecode(jsonEncode(presets.obj('mf_dg22'))));
        (rule['operations']['list']['steps'][0]['body'] as Map)['extra'] = expr;
        expect(() => ParserRule.fromJson(rule), throwsA(_code('INVALID_RULE')));
      }
      for (final header in ['Cookie', 'Authorization', 'Host', 'Connection']) {
        final rule = asJson(jsonDecode(jsonEncode(presets.obj('mf_dg22'))));
        (rule['operations']['list']['steps'][0]['headers'] as Map)[header] =
            'secret';
        expect(() => ParserRule.fromJson(rule), throwsA(_code('INVALID_RULE')));
      }
      final rule = presets.obj('mf_dg22');
      rule['operations']['list']['steps'][0]['url'] =
          'https://127.0.0.1/private';
      expect(() => ParserRule.fromJson(rule), throwsA(_code('INVALID_RULE')));
    },
  );
  test(
    'Signed prompts support old manifests and keep the same rule version',
    () {
      final old = ParserBundle.verify(_json('bundle-1'), _publicKey, now: _now);
      expect(
        old.sites.single.passwordPrompt.message,
        ParserPasswordPrompt.defaultMessage,
      );
      expect(old.sites.single.passwordPrompt.buttonEnabled, isTrue);
      expect(old.sites.single.passwordPrompt.format, 'text');
      expect(old.sites.single.passwordPrompt.autoFill, isTrue);
      final updated = ParserBundle.verify(
        _json('bundle-prompt'),
        _publicKey,
        now: _now,
      );
      final prompt = updated.sites.single.passwordPrompt;
      expect(prompt.title, '领取本通道密码');
      expect(prompt.message, '当前密码不可用，请领取后再试。\n验证通过后会自动共享。');
      expect(prompt.buttonText, '获取今日密码');
      expect(updated.sites.single.version, old.sites.single.version);
      expect(updated.sites.single.rule.json, old.sites.single.rule.json);
      final hidden = ParserBundle.verify(
        _json('bundle-prompt-2'),
        _publicKey,
        now: _now,
      );
      expect(hidden.sites.single.passwordPrompt.buttonEnabled, isFalse);
      final rich = ParserBundle.verify(
        _json('bundle-rich-prompt'),
        _publicKey,
        now: _now,
      );
      expect(rich.sites.single.passwordPrompt.format, 'markdown');
      expect(rich.sites.single.passwordPrompt.autoFill, isFalse);
      expect(rich.sites.single.version, old.sites.single.version);
      expect(rich.sites.single.rule.json, old.sites.single.rule.json);
      for (final fixture in ['bundle-bad-format', 'bundle-bad-autofill']) {
        expect(
          () => ParserBundle.verify(_json(fixture), _publicKey, now: _now),
          throwsA(_code('RULE_SIGNATURE')),
        );
      }
      expect(
        () => ParserBundle.verify(
          _json('bundle-bad-prompt'),
          _publicKey,
          now: _now,
        ),
        throwsA(_code('RULE_SIGNATURE')),
      );
    },
  );
  test(
    'Prompt text accepts Unicode and multiline content with bounded fields',
    () {
      final defaults = ParserPasswordPrompt.fromJson({
        'title': '',
        'message': ' ',
        'buttonText': '',
      });
      expect(defaults.title, isEmpty);
      expect(defaults.message, ParserPasswordPrompt.defaultMessage);
      expect(defaults.buttonText, ParserPasswordPrompt.defaultButtonText);
      expect(
        ParserPasswordPrompt.fromJson({'message': '密' * 4000}).message.length,
        4000,
      );
      for (final invalid in <Object>[
        'invalid',
        [1],
        {'title': 4},
        {'title': '题' * 121},
        {'message': '密' * 4001},
        {'buttonText': '领' * 33},
        {'buttonEnabled': 'false'},
        {'autoFill': 'false'},
        {'autoFill': 0},
        {'format': 'html'},
        {'format': null},
        {'message': 'bad\x00text'},
      ]) {
        expect(
          () => ParserPasswordPrompt.fromJson(invalid),
          throwsFormatException,
        );
      }
    },
  );
  test('Expressions keep large IDs, boolean semantics and map null checks', () {
    final expr = RuleExpression();
    expect(
      expr.eval({
        r'$op': 'int',
        'args': [BaiduPublicFixture.fileId],
      }, {}),
      9007199254740993,
    );
    expect(
      expr.eval({
        r'$op': 'eq',
        'args': [true, 1],
      }, {}),
      false,
    );
    expect(
      expr.eval({
        r'$op': 'coalesce',
        'args': [null, '', 0, 3],
      }, {}),
      0,
    );
    expect(
      () => expr.eval({
        r'$op': 'map',
        'args': [
          null,
          {r'$ref': 'item.id'},
        ],
      }, {}),
      throwsA(_code('RULE_RESPONSE')),
    );
  });
  test(
    'Rule engine preserves directory fields and exact download identity',
    () async {
      final fixture = BaiduPublicFixture(), http = FakeHttp();
      final transport = FakeHttp(fixture.respond);
      final engine = ParserRuleEngine(transport),
          rule = ParserRule.fromJson(presets.obj('mf_dg22'));
      final listing = await engine.execute(
        rule,
        'list',
        _input,
        password: 'testing',
        device: 'stable-device',
      );
      expect(listing.list('list').last.integer('isdir'), 1);
      expect(
        listing.list('list').first.str('fs_id'),
        BaiduPublicFixture.fileId,
      );
      final result = await engine.execute(
        rule,
        'download',
        _input,
        password: 'testing',
        device: 'stable-device',
      );
      expect(result.str('fs_id'), BaiduPublicFixture.fileId);
      expect(http.calls, isEmpty);
      fixture.returnedId = 'wrong-id';
      await expectLater(
        engine.execute(
          rule,
          'download',
          _input,
          password: 'testing',
          device: 'stable-device',
        ),
        throwsA(_code('RULE_FILE_MISMATCH')),
      );
    },
  );

  test(
    'mf rule carries listing dlink into the download request and supports older inputs',
    () async {
      final fixture = BaiduPublicFixture()
        ..dlink = 'https://d.pcs.baidu.com/file/video?sign=exact%2Bvalue';
      final transport = FakeHttp(fixture.respond);
      final engine = ParserRuleEngine(transport);
      final rule = ParserRule.fromJson(presets.obj('mf_dg22'));
      final listing = await engine.execute(
        rule,
        'list',
        _input,
        password: 'testing',
        device: 'stable-device',
      );
      final file = listing.list('list').first;
      expect(file.str('dlink'), fixture.dlink);
      await engine.execute(
        rule,
        'download',
        {..._input, 'file': file},
        password: 'testing',
        device: 'stable-device',
      );
      expect(transport.calls.last.json['dlink'], [fixture.dlink]);
      await engine.execute(
        rule,
        'download',
        _input,
        password: 'testing',
        device: 'stable-device',
      );
      expect(transport.calls.last.json['dlink'], isEmpty);
    },
  );
  test(
    'CheckRand matches PHP and preserves complete candidate passwords',
    () async {
      final fixture = BaiduPublicFixture();
      final http = FakeHttp(
        (request) => fixture.respond(
          RecordedRequest(
            request.method,
            request.url.replaceFirst('mf.dp.wpurl.cc', 'mf.dg22.top'),
            request.body,
            request.headers,
          ),
        ),
      );
      await ParserRuleEngine(http).execute(
        ParserRule.fromJson(presets.obj('dp_wpurl')),
        'download',
        _input,
        password: ' 长度不限-中文! ',
        device: 'stable-device',
      );
      final payload = http.calls.single.json;
      final hash = payload.remove('rand1');
      final rand2 = payload.remove('rand2');
      expect(
        payload.remove('rand3'),
        sha1.convert(utf8.encode(rand2 as String)).toString(),
      );
      expect(hash, sha1.convert(utf8.encode(jsonEncode(payload))).toString());
      expect(payload['parse_password'], ' 长度不限-中文! ');
    },
  );
  test(
    'WPURL unwraps file IDs without accepting mismatches or extra IDs',
    () async {
      final fixture = BaiduPublicFixture();
      const id = BaiduPublicFixture.fileId;
      for (final (returned, valid) in <(Object, bool)>[
        (id, true),
        ([id], true),
        (['wrong-id'], false),
        (<String>[], false),
        ([id, '2'], false),
      ]) {
        final http = FakeHttp((request) {
          final response = fixture.respond(
            RecordedRequest(
              request.method,
              request.url.replaceFirst('mf.dp.wpurl.cc', 'mf.dg22.top'),
              request.body,
              request.headers,
            ),
          );
          final body = response.json;
          (body['data'] as List).first['fs_id'] = returned;
          return jsonResponse(body, response.status);
        });
        final download = ParserRuleEngine(http).execute(
          ParserRule.fromJson(presets.obj('dp_wpurl')),
          'download',
          _input,
          password: 'fixture-password',
          device: 'stable-device',
        );
        if (valid) {
          expect((await download).str('fs_id'), id);
        } else {
          await expectLater(download, throwsA(_code('RULE_FILE_MISMATCH')));
        }
      }
    },
  );
  test(
    'XDown8 lists and downloads with the existing signed rule engine',
    () async {
      final fixture = BaiduPublicFixture();
      final http = FakeHttp(
        (request) => fixture.respond(
          RecordedRequest(
            request.method,
            request.url.replaceFirst('jx.xdown8.top', 'mf.dg22.top'),
            request.body,
            request.headers,
          ),
        ),
      );
      final rule = ParserRule.fromJson(presets.obj('xdown8'));
      final engine = ParserRuleEngine(http);
      final listing = await engine.execute(
        rule,
        'list',
        _input,
        password: '中文密码-不限字数!',
        device: 'stable-device',
      );
      final file = listing.list('list').first;
      final download = await engine.execute(
        rule,
        'download',
        {..._input, 'file': file, 'state': listing.obj('state')},
        password: '中文密码-不限字数!',
        device: 'stable-device',
      );
      expect(download.str('fs_id'), file.str('fs_id'));
      expect(http.calls, hasLength(2));
      for (final request in http.calls) {
        expect(request.uri.host, 'jx.xdown8.top');
        expect(request.headers['Origin'], 'https://jx.xdown8.top');
        expect(request.headers['User-Agent'], 'Dart/3.13 (dart:io)');
        final payload = Map<String, dynamic>.of(request.json);
        final hash = payload.remove('rand1');
        final nonce = payload.remove('rand2') as String;
        expect(
          payload.remove('rand3'),
          sha1.convert(utf8.encode(nonce)).toString(),
        );
        expect(hash, sha1.convert(utf8.encode(jsonEncode(payload))).toString());
        expect(payload['parse_password'], '中文密码-不限字数!');
      }
    },
  );
  test(
    'Lowercase rule headers are preserved without duplicate defaults',
    () async {
      final raw = presets.obj('mf_dg22');
      raw['operations']['list']['steps'][0]['headers'] = {
        'user-agent': 'fixture-browser',
        'accept': 'application/custom+json',
      };
      final fixture = BaiduPublicFixture();
      final http = FakeHttp(fixture.respond);
      await ParserRuleEngine(http).execute(
        ParserRule.fromJson(raw),
        'list',
        _input,
        password: '中文密码-不限字数!',
        device: 'stable-device',
      );
      final headers = http.calls.single.headers;
      expect(headers['user-agent'], 'fixture-browser');
      expect(headers['accept'], 'application/custom+json');
      expect(
        headers.keys.where((key) => key.toLowerCase() == 'user-agent'),
        hasLength(1),
      );
      expect(
        headers.keys.where((key) => key.toLowerCase() == 'accept'),
        hasLength(1),
      );
    },
  );
  for (final status in [400, 429, 503]) {
    test(
      'Password rejection cannot hide an HTTP outage or quota: $status',
      () async {
        final engine = ParserRuleEngine(
          FakeHttp((_) => jsonResponse({'code': 20016}, status)),
        );
        await expectLater(
          engine.execute(
            ParserRule.fromJson(presets.obj('mf_dg22')),
            'list',
            _input,
            password: 'testing',
            device: 'stable-device',
          ),
          throwsA(
            _code(switch (status) {
              400 => 'password_rejected',
              429 => 'quota_exhausted',
              _ => 'upstream_unavailable',
            }),
          ),
        );
      },
    );
  }
  test(
    'Pagination accumulates unique files and rejects endless pages',
    () async {
      final raw = presets.obj('mf_dg22');
      raw['operations']['list']['steps'][0]['body']['page'] = {
        r'$ref': 'page.number',
      };
      raw['operations']['list']['pagination'] = {
        'maxPages': 3,
        'hasMore': {r'$ref': 'last.data.more'},
      };
      var repeat = false;
      final http = FakeHttp((r) {
        final page = repeat ? 1 : r.json.integer('page');
        return jsonResponse({
          'code': 200,
          'data': {
            'more': page == 1,
            'list': [
              {
                'fs_id': '$page',
                'server_filename': 'page-$page',
                'isdir': 0,
                'path': '/page-$page',
              },
            ],
          },
        });
      });
      final engine = ParserRuleEngine(http), rule = ParserRule.fromJson(raw);
      expect(
        (await engine.execute(
          rule,
          'list',
          _input,
          password: 'testing',
          device: 'device',
        )).list('list'),
        hasLength(2),
      );
      repeat = true;
      await expectLater(
        engine.execute(
          rule,
          'list',
          _input,
          password: 'testing',
          device: 'device',
        ),
        throwsA(_code('RULE_PAGINATION')),
      );
    },
  );
  test('KDown response decoder reads actual encrypted upstream failure', () {
    final text = File(
      '${_fixtures.path}/kdown-upstream-error.txt',
    ).readAsStringSync();
    final result = asJson(ParserRuleCodecs.decode('kdown', text));
    expect(result['success'], false);
    expect(result.str('message'), contains('免费版接口获取下载直链失败'));
    expect(
      ParserRuleCodecs.rc4(
        utf8.encode('Plaintext'),
        'Key',
      ).map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
      'bbf316e8d940af0ad3',
    );
  });

  group('remote rule hub integration', () {
    late Directory directory;
    late Vault vault;
    late ParserRuleHub hub;
    late FakeHttp http;
    late BaiduPublicFixture fixture;
    late int revision;
    String? manifest;
    late bool unavailable, rejected, missingPassword, rejectParserPassword;
    late DateTime now;
    ParserRuleHub createHub() => ParserRuleHub(
      store: vault,
      directory: directory,
      http: http,
      url: 'https://hub.example.com',
      apiKey: 'fixture-app-key',
      publicKey: _publicKey,
      clock: () => now,
    );
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('wenxi-rule-test-');
      vault = Vault(StateStore.memory());
      fixture = BaiduPublicFixture();
      revision = 1;
      manifest = null;
      unavailable = false;
      rejected = false;
      missingPassword = false;
      rejectParserPassword = false;
      now = _now;
      http = FakeHttp((r) {
        if (r.uri.host == 'hub.example.com') {
          expect(r.headers['Authorization'], 'Bearer fixture-app-key');
          expect(r.headers['Cookie'], isNull);
          if (unavailable) {
            throw const ParserRuleError('RULE_NETWORK', 'test outage');
          }
          if (r.uri.path == '/v1/sites') {
            return jsonResponse({
              'ok': true,
              'data': {
                'sites': [
                  for (final id in ['mf_dg22', 'generic_test'])
                    {'id': id, 'version': rejected ? 2 : 1},
                ],
              },
            });
          }
          if (r.uri.path == '/v1/rules') {
            return jsonResponse({
              'ok': true,
              'data': _json(manifest ?? 'bundle-$revision'),
            });
          }
          if (r.uri.path.endsWith('/password')) {
            return jsonResponse({
              'ok': true,
              'data': {
                'password': missingPassword
                    ? null
                    : rejected
                    ? 'new-code'
                    : BaiduPublicFixture.password,
                'version': rejected ? 2 : 1,
                'cacheFor': 300,
                'status': missingPassword ? 'missing' : 'available',
              },
            });
          }
          if (r.uri.path.endsWith('/report')) {
            rejected = true;
            return jsonResponse({
              'ok': true,
              'data': {'status': 'available'},
            });
          }
          if (r.uri.path.endsWith('/submissions')) {
            missingPassword = false;
            return jsonResponse({
              'ok': true,
              'data': {'id': 'a' * 32, 'status': 'accepted'},
            });
          }
          throw StateError('Unexpected hub path ${r.uri.path}');
        }
        expect(
          r.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(
          r.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('cookie')),
        );
        if (rejectParserPassword) return jsonResponse({'code': 20016}, 400);
        return fixture.respond(r);
      });
      hub = createHub();
    });
    tearDown(() async {
      await hub.close();
      await directory.delete(recursive: true);
    });
    test(
      'Legacy mf uses the manual grant even when a UC account is available',
      () async {
        manifest = 'bundle-rich-prompt';
        await hub.refresh(force: true);
        await hub.submitPassword('mf_dg22', BaiduPublicFixture.password);
        final grant = await hub.grantPassword('mf_dg22');
        final account = Credential('active UC', {
          'primary': '__pus=active-uc',
        }, updatedAt: 9);
        await vault.putCredential(CloudPlatform.uc, account);
        var fetches = 0;
        final passwords = BaiduPublicPasswords(
          http,
          store: vault,
          clock: () => now,
          fetchAuthenticated: (used) async {
            expect(used.sameAs(account), true);
            fetches++;
            return '账号转存取得的密码';
          },
        );
        addTearDown(passwords.close);
        final parser = BaiduPublicParser(
          http,
          store: vault,
          hub: hub,
          passwords: passwords,
        );
        await parser.openShare(fixture.link, passwordGrant: grant);
        expect(
          http.calls.last.json['parse_password'],
          BaiduPublicFixture.password,
        );
        await expectLater(
          parser.openShare(fixture.link),
          throwsA(isA<ParserPasswordRequired>()),
        );
        expect(fetches, 0);
      },
    );
    test(
      'Legacy mf requires manual input without a grant and does not fetch a UC password',
      () async {
        manifest = 'bundle-rich-prompt';
        missingPassword = true;
        await hub.refresh(force: true);
        await vault.putCredential(
          CloudPlatform.uc,
          Credential('active UC', {'primary': '__pus=active-uc'}, updatedAt: 9),
        );
        var fetches = 0;
        final passwords = BaiduPublicPasswords(
          http,
          store: vault,
          clock: () => now,
          fetchAuthenticated: (_) async {
            fetches++;
            return '自动取得的当日密码';
          },
        );
        addTearDown(passwords.close);
        final parser = BaiduPublicParser(
          http,
          store: vault,
          hub: hub,
          passwords: passwords,
        );
        final first = http.calls.length;
        await expectLater(
          parser.openShare(fixture.link),
          throwsA(isA<ParserPasswordRequired>()),
        );
        final calls = http.calls.skip(first).toList();
        expect(fetches, 0);
        expect(calls, isEmpty);
      },
    );
    test(
      'manual metadata reads no password and submits the current version',
      () async {
        rejected = true;
        await hub.passwordMetadata('mf_dg22');
        expect(http.calls.map((r) => r.uri.path), ['/v1/sites']);
        await expectLater(
          hub.grantPassword('mf_dg22'),
          throwsA(isA<AppException>()),
        );
        final result = await hub.submitPassword('mf_dg22', 'new-code');
        expect(result.str('status'), 'accepted');
        final submission = http.calls.singleWhere(
          (r) => r.uri.path.endsWith('/submissions'),
        );
        expect(submission.json['baseVersion'], 2);
        expect(http.calls.last.uri.path, '/v1/sites/mf_dg22/password');
      },
    );
    test(
      'manual approval survives plain-state restart for the same share and expires at Beijing midnight',
      () async {
        await hub.close();
        final dataDirectory = Directory('${directory.path}/state');
        vault = Vault(await StateStore.open(dataDirectory));
        hub = createHub();
        manifest = 'bundle-rich-prompt';
        await hub.refresh(force: true);
        await hub.submitPassword('mf_dg22', BaiduPublicFixture.password);
        final grant = await hub.grantPassword('mf_dg22');
        final approval = hub.grantedPassword('mf_dg22', grant)!;
        expect(
          approval.expiresAt.toUtc().add(const Duration(hours: 8)).hour,
          0,
        );
        expect(
          approval.expiresAt.toUtc().add(const Duration(hours: 8)).minute,
          0,
        );
        expect(hub.grantedPassword('generic_test', grant), isNull);
        final parser = BaiduPublicParser(http, store: vault, hub: hub);
        final session = await parser.openShare(
          fixture.link,
          passwordGrant: grant,
        );
        final file = (await parser.list(session, '/')).first;
        expect(
          jsonEncode(session.toJson()),
          isNot(contains(BaiduPublicFixture.password)),
        );
        expect(
          jsonEncode(decodePlainState(await vault.store.file!.readAsBytes())),
          contains(BaiduPublicFixture.password),
        );
        await hub.close();
        vault.store.dispose();
        vault = Vault(await StateStore.open(dataDirectory));
        addTearDown(() => vault.store.dispose());
        hub = createHub();
        now = now.add(const Duration(minutes: 6));
        unavailable = true;
        await hub.refresh(force: true);
        final restarted = BaiduPublicParser(http, store: vault, hub: hub);
        await restarted.download(
          BrowseSession.fromJson(session.toJson()),
          CloudFile.fromJson(file.toJson()),
        );
        final requests = http.calls.length;
        await expectLater(
          restarted.openShare(fixture.link),
          throwsA(isA<ParserPasswordRequired>()),
        );
        expect(http.calls.length, requests);
        now = approval.expiresAt.subtract(const Duration(milliseconds: 1));
        expect(hub.grantedPassword('mf_dg22', grant), isNotNull);
        now = approval.expiresAt;
        expect(hub.grantedPassword('mf_dg22', grant), isNull);
        await expectLater(
          restarted.ensurePassword(session),
          throwsA(isA<ParserPasswordRequired>()),
        );
      },
    );
    test(
      'explicit password rejection revokes a manual approval without automatically substituting another password',
      () async {
        await hub.refresh(force: true);
        await hub.submitPassword('mf_dg22', BaiduPublicFixture.password);
        final grant = await hub.grantPassword('mf_dg22');
        rejectParserPassword = true;
        final parser = BaiduPublicParser(http, store: vault, hub: hub);
        await expectLater(
          parser.openShare(fixture.link, passwordGrant: grant),
          throwsA(isA<ParserPasswordRequired>()),
        );
        expect(hub.grantedPassword('mf_dg22', grant), isNull);
        expect(
          http.calls.where((r) => r.uri.host == 'mf.dg22.top'),
          hasLength(1),
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/report')),
          hasLength(1),
        );
      },
    );
    test(
      'hub-backed parser keeps video dlink through listing and task restoration',
      () async {
        fixture.fileName = '视频.mp4';
        fixture.dlink =
            'https://d.pcs.baidu.com/file/video?sign=initial%2Bhint';
        expect(await hub.refresh(force: true), true);
        final parser = BaiduPublicParser(http, store: vault, hub: hub);
        await hub.submitPassword('mf_dg22', BaiduPublicFixture.password);
        final grant = await hub.grantPassword('mf_dg22');
        final session = await parser.openShare(
          fixture.link,
          passwordGrant: grant,
        );
        final file = (await parser.list(session, '/')).first;
        await parser.download(session, file);
        expect(http.calls.last.json['dlink'], [fixture.dlink]);
        fixture.dlink =
            'https://d.pcs.baidu.com/file/video?sign=updated%2Bhint';
        final restarted = BaiduPublicParser(http, store: vault, hub: hub);
        await restarted.download(
          BrowseSession.fromJson(session.toJson()),
          CloudFile.fromJson(file.toJson()),
        );
        expect(http.calls.last.json['dlink'], [fixture.dlink]);
      },
    );
    test(
      'new shares get updates, running sessions pin original rule, restart retains both',
      () async {
        expect(await hub.refresh(force: true), true);
        final parser = BaiduPublicParser(http, store: vault, hub: hub);
        await hub.submitPassword('mf_dg22', BaiduPublicFixture.password);
        final grant = await hub.grantPassword('mf_dg22');
        final session = await parser.openShare(
          fixture.link,
          passwordGrant: grant,
        );
        final file = (await parser.list(session, '/')).first;
        expect(session.meta('parserRuleBundle'), hasLength(64));
        revision = 2;
        await hub.refresh(force: true);
        await parser.download(session, file);
        expect(http.calls.last.uri.queryParameters['v'], isNull);
        final newSession = await parser.openShare(
          fixture.link,
          passwordGrant: await hub.grantPassword('mf_dg22'),
        );
        await parser.download(newSession, file);
        expect(http.calls.last.uri.queryParameters['v'], '2');
        await hub.close();
        hub = ParserRuleHub(
          store: vault,
          directory: directory,
          http: http,
          url: 'https://hub.example.com',
          apiKey: 'fixture-app-key',
          publicKey: _publicKey,
          clock: () => now,
        );
        unavailable = true;
        await hub.refresh(force: true);
        expect(hub.sites.single.version, 2);
        expect(
          (await hub.snapshot(
            session.meta('parserRuleBundle'),
            'mf_dg22',
          )).version,
          1,
        );
      },
    );
    test(
      'network failure and lower revision retain working cached rules',
      () async {
        revision = 2;
        await hub.refresh(force: true);
        unavailable = true;
        expect(await hub.refresh(force: true), false);
        expect(hub.sites.single.version, 2);
        unavailable = false;
        revision = 1;
        expect(await hub.refresh(force: true), false);
        expect(hub.sites.single.version, 2);
        expect(hub.lastError, 'RULE_ROLLBACK');
      },
    );
    test(
      'withdrawn sites cannot silently bypass remote disabled state',
      () async {
        await hub.refresh(force: true);
        revision = 3;
        await hub.refresh(force: true);
        expect(hub.sites, isEmpty);
        expect(hub.hasManifest, true);
        await expectLater(
          hub.forNewShare(),
          throwsA(_code('RULE_UNAVAILABLE')),
        );
      },
    );
    test(
      'missing shared password prompts input and accepted submission rereads shared value',
      () async {
        await hub.refresh(force: true);
        missingPassword = true;
        await expectLater(
          hub.password('mf_dg22'),
          throwsA(isA<ParserPasswordRequired>()),
        );
        final submitted = await hub.submitPassword('mf_dg22', '任意长度Password !');
        expect(submitted.str('status'), 'accepted');
        final submission = http.calls
            .where((c) => c.uri.path.endsWith('/submissions'))
            .single;
        expect(submission.json['password'], '任意长度Password !');
        expect(submission.json['baseVersion'], 1);
        expect(submission.headers['Idempotency-Key']!.length, 32);
        expect(
          (await hub.password('mf_dg22')).value,
          BaiduPublicFixture.password,
        );
      },
    );
    test(
      'outage temporarily reuses known password, explicit missing state clears it',
      () async {
        final password = await hub.password('mf_dg22');
        unavailable = true;
        now = now.add(const Duration(minutes: 6));
        expect((await hub.password('mf_dg22')).value, password.value);
        unavailable = false;
        missingPassword = true;
        await expectLater(
          hub.password('mf_dg22', force: true),
          throwsA(isA<ParserPasswordRequired>()),
        );
      },
    );
    test(
      'rejected passwords remain blocked after a failed report and restart',
      () async {
        final old = await hub.password('mf_dg22');
        unavailable = true;
        await hub.reportRejected('mf_dg22', old);
        unavailable = false;
        await expectLater(
          hub.password('mf_dg22', force: true),
          throwsA(isA<ParserPasswordRequired>()),
        );
        await hub.close();
        hub = createHub();
        await expectLater(
          hub.password('mf_dg22'),
          throwsA(isA<ParserPasswordRequired>()),
        );
        rejected = true;
        expect((await hub.password('mf_dg22')).value, 'new-code');
      },
    );
    test(
      'late old rejection cannot invalidate a newer cached or rejected version',
      () async {
        final old = await hub.password('mf_dg22');
        rejected = true;
        final current = await hub.password('mf_dg22', force: true);
        unavailable = true;
        await hub.reportRejected('mf_dg22', old);
        expect((await hub.password('mf_dg22')).value, current.value);
        await hub.reportRejected('mf_dg22', current);
        await hub.reportRejected('mf_dg22', old);
        unavailable = false;
        await expectLater(
          hub.password('mf_dg22'),
          throwsA(isA<ParserPasswordRequired>()),
        );
      },
    );
    test(
      'cancelling one password waiter does not cancel another download',
      () async {
        await hub.close();
        final started = Completer<void>(), release = Completer<void>();
        http = FakeHttp((_) async {
          started.complete();
          await RequestScope.cancellable(release.future);
          return jsonResponse({
            'ok': true,
            'data': {'password': 'shared-code', 'version': 1, 'cacheFor': 300},
          });
        });
        hub = createHub();
        final firstScope = RequestScope(), secondScope = RequestScope();
        final first = firstScope.run(() => hub.password('mf_dg22'));
        final cancelled = expectLater(first, throwsA(isA<AppException>()));
        await started.future;
        final second = secondScope.run(() => hub.password('mf_dg22'));
        firstScope.cancel();
        await cancelled;
        release.complete();
        expect((await second).value, 'shared-code');
        expect(http.calls, hasLength(1));
      },
    );
    test(
      'both rejected parser attempts stop reusing the second password',
      () async {
        manifest = 'bundle-generic';
        await hub.refresh(force: true);
        rejectParserPassword = true;
        final parser = BaiduPublicParser(http, store: vault, hub: hub);
        await expectLater(
          parser.openShare(fixture.link),
          throwsA(isA<ParserPasswordRequired>()),
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/report')),
          hasLength(2),
        );
        await expectLater(
          hub.password('generic_test'),
          throwsA(isA<ParserPasswordRequired>()),
        );
      },
    );
    test('closing the hub cancels its outstanding password request', () async {
      await hub.close();
      final started = Completer<void>(), never = Completer<void>();
      http = FakeHttp((_) async {
        started.complete();
        await RequestScope.cancellable(never.future);
        throw StateError('Cancelled transport must not return credentials');
      });
      hub = createHub();
      final request = hub.password('mf_dg22');
      final cancelled = expectLater(request, throwsA(isA<AppException>()));
      await started.future;
      await hub.close();
      await cancelled;
    });
    for (final restartBeforeRefresh in [false, true]) {
      test(
        'verified response repairs a corrupt archive, restart first: $restartBeforeRefresh',
        () async {
          await hub.refresh(force: true);
          final archive = (await hub.root.list(recursive: true).toList())
              .whereType<File>()
              .singleWhere((file) => file.path.endsWith('.json'));
          await archive.writeAsString('{corrupted');
          if (restartBeforeRefresh) {
            await hub.close();
            hub = createHub();
          }
          await hub.refresh(force: true);
          expect(hub.lastError, isNull);
          expect(jsonDecode(await archive.readAsString()), isA<Map>());
          await hub.close();
          hub = createHub();
          unavailable = true;
          await hub.refresh(force: true);
          expect(hub.sites.single.version, 1);
        },
      );
    }
    test(
      'concurrent device initialization keeps one identity across restart',
      () async {
        final ids = await Future.wait(
          List.generate(6, (_) => hub.device('kdown_free')),
        );
        expect(ids.toSet(), hasLength(1));
        await hub.close();
        hub = createHub();
        expect(await hub.device('kdown_free'), ids.first);
      },
    );
  });
}
