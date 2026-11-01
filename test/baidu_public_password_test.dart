import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_command_resolver.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/providers/baidu_public_parser.dart';
import 'package:asterlink/data/providers/baidu_public_command.dart';
import 'package:asterlink/data/providers/baidu_public_password.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_request.dart';
import 'baidu_public_parser_support.dart';
import 'support.dart';

class _UnwritableVault extends Vault {
  _UnwritableVault(super.store);
  @override
  Future<void> putSecret(String key, String value) async {
    throw const AppException('fixture full disk');
  }
}

class _UcSource {
  String command = '執每日更新铁观音生效';
  bool pageUnavailable = false;
  String prefix = '========测试密码========\n下文不参与密码';
  String contentType = 'text/plain';
  String range = 'bytes 0-4095/345196';
  int status = 206;
  bool ambiguous = false;
  final requests = <RecordedRequest>[];
  Json file(String id, String name) => {
    'fid': id,
    'file_name': name,
    'size': 345196,
    'share_fid_token': 'guest-file-token',
    'isdir': 0,
  };

  HttpResult respond(RecordedRequest request) {
    requests.add(request);
    expect(request.headers.toString(), isNot(contains('private-account')));
    expect(request.body.toString(), isNot(contains('private-account')));
    if (request.uri.host == 'www.yuque.com') {
      expect(request.uri.path, endsWith('/markdown'));
      expect(request.headers['Cookie'], isNull);
      if (pageUnavailable) {
        return const HttpResult(503, '<html>maintenance</html>');
      }
      return HttpResult(
        200,
        '<article><pre><code>$command</code></pre></article>',
      );
    }
    if (request.uri.host == 'utoken2.uc.cn') {
      expect(request.json['clipboard'], command);
      return jsonResponse({
        'success': true,
        'code': 'OK',
        'data': {'androidUrl': 'https://drive.uc.cn/s/passwordfixture'},
      });
    }
    if (request.uri.path.endsWith('/share/sharepage/token')) {
      expect(request.headers['Cookie'], isEmpty);
      return jsonResponse({
        'status': 200,
        'code': 0,
        'data': {'stoken': 'guest-share-token', 'first_fid': '0'},
      });
    }
    if (request.uri.path.endsWith('/transfer_share/detail')) {
      expect(request.headers['Cookie'], isEmpty);
      return jsonResponse({
        'status': 200,
        'code': 0,
        'data': {
          'list': [
            file('text', '每日文本.txt.zip'),
            if (ambiguous) file('other', '另一个.txt'),
          ],
        },
      });
    }
    if (request.uri.path.endsWith('/file/download')) {
      expect(request.json['pwd_id'], 'passwordfixture');
      expect(request.headers['Cookie'], isEmpty);
      return HttpResult(
        200,
        encoded({
          'status': 200,
          'code': 0,
          'data': [
            {
              'fid': 'text',
              'size': 345196,
              'download_url': 'https://dl.uc.cn/password-text',
            },
          ],
        }),
        {
          'set-cookie': ['__pugs=guest-only; Path=/'],
        },
      );
    }
    if (request.uri.host == 'dl.uc.cn') {
      expect(request.headers['Cookie'], '__pugs=guest-only');
      if (request.headers['Range'] == 'bytes=0-0') {
        return const HttpResult(206, '=', {
          'content-range': ['bytes 0-0/345196'],
          'content-length': ['1'],
        });
      }
      expect(request.headers['Range'], 'bytes=0-4095');
      return HttpResult(status, prefix, {
        'content-range': [range],
        'content-type': [contentType],
      });
    }
    throw StateError('Unexpected password request ${request.uri.path}');
  }

  BaiduPublicPasswords passwords({
    CredentialStore? store,
    DateTime Function()? clock,
  }) => BaiduPublicPasswords(
    FakeHttp(respond),
    store: store,
    clock: clock,
    commandKeys: CloudCommandKeys(uc: 'B' * 24),
    fetchBackup: () => throw const AppException('backup unavailable'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Web UC command reads a guest text prefix and never consults the daily source',
    () async {
      final source = _UcSource()..command = '网页当前口令';
      final passwords = source.passwords();
      expect(await passwords.fromUcCommand(source.command), '测试密码');
      expect(
        source.requests.where((r) => r.uri.host == 'www.yuque.com'),
        isEmpty,
      );
      source.prefix = '==新123中文ABC密码==\r\n第二行不是密码';
      expect(await passwords.fromUcCommand(source.command), '新中文密码');
      expect(
        source.requests.where((r) => r.uri.host == 'utoken2.uc.cn').length,
        2,
      );
      await passwords.close();
    },
  );
  late DateTime now;
  late StateStore state;
  late Vault vault;
  late BaiduPublicPasswords passwords;
  late int fetches;
  late String next;
  late bool fail;
  late int backupFetches;
  String? backupValue;

  setUp(() {
    now = DateTime.utc(2026, 10, 11, 15, 59, 59);
    state = StateStore.memory({
      'credentials': {
        CloudPlatform.uc.key: Credential('UC fixture', {
          'primary': '__pus=private-account-cookie',
        }, updatedAt: 1).toJson(),
      },
    });
    vault = Vault(state);
    fetches = 0;
    next = '今日密码';
    fail = false;
    backupFetches = 0;
    backupValue = null;
    passwords = BaiduPublicPasswords(
      FakeHttp(),
      store: vault,
      clock: () => now,
      fetch: () async {
        fetches++;
        if (fail) throw const AccountLoginRequired('private-account-cookie');
        return next;
      },
      fetchAuthenticated: (_) async {
        fetches++;
        if (fail) throw const AccountLoginRequired('private-account-cookie');
        return next;
      },
      fetchBackup: () async {
        backupFetches++;
        if (backupValue == null) throw const AppException('backup unavailable');
        return backupValue!;
      },
    );
  });

  for (final separator in ['\n', '\r\n', '\r']) {
    test(
      'only Chinese from the first line is extracted: ${jsonEncode(separator)}',
      () {
        expect(
          BaiduPublicPasswords.extract(
            '\uFEFF========测1试_密 码========$separator'
            '忽略小说正文',
          ),
          '测试密码',
        );
      },
    );
  }
  test('Chinese extension characters and a one-line file are supported', () {
    expect(BaiduPublicPasswords.extract('==\u{20000}密码=='), '\u{20000}密码');
  });
  for (final input in [
    '',
    '\n第二行密码',
    'only-ascii\n第二行密码',
    '<html>错误</html>',
    'PK\x03\x04密码',
    '密\uFFFD码',
    '中' * (BaiduPublicPasswords.prefixBytes + 1),
    '${'=' * BaiduPublicPasswords.prefixBytes}密码',
  ]) {
    test('an invalid first line cannot become a password: ${input.length}', () {
      expect(
        () => BaiduPublicPasswords.extract(input),
        throwsA(isA<AppException>()),
      );
    });
  }

  test('first-line Chinese passwords do not have a fixed character count', () {
    for (final length in [1, 2, 3, 4, 12, 33, 256]) {
      expect(
        BaiduPublicPasswords.extract('==${'中' * length}==\n正文'),
        '中' * length,
      );
    }
  });

  test('Gitee accepts text, JSON strings and named password fields', () {
    for (final content in [
      '====远程备用密码====\n忽略正文',
      '\uFEFF远程备用密码',
      encoded('远程备用密码'),
      encoded({'password': '远程备用密码'}),
      encoded({'parse_password': '远程备用密码'}),
      encoded({'密码': '远程备用密码'}),
      encoded({
        'data': {'password': '远程备用密码'},
      }),
    ]) {
      expect(BaiduPublicPasswords.extractBackup(content), '远程备用密码');
    }
    for (final content in [
      '<html>访问受限</html>',
      '{broken',
      '{"other":"错误"}',
      '[]',
    ]) {
      expect(
        () => BaiduPublicPasswords.extractBackup(content),
        throwsA(isA<AppException>()),
      );
    }
  });

  test(
    'Gitee is used only after UC fails, then cached across restart',
    () async {
      fail = true;
      backupValue = '备用有效密码';
      final value = await passwords.get();
      expect(value.value, backupValue);
      expect(value.source, BaiduPublicPasswordSource.gitee);
      expect(fetches, 1);
      expect(backupFetches, 1);
      final reopened = BaiduPublicPasswords(
        FakeHttp(),
        store: vault,
        clock: () => now,
      );
      expect((await reopened.get()).value, backupValue);
      expect((await reopened.get()).source, BaiduPublicPasswordSource.gitee);
    },
  );

  test('UC success never requests Gitee', () async {
    await passwords.get();
    expect(backupFetches, 0);
  });

  test(
    'daily startup prefetch and downloads share one persisted lookup',
    () async {
      await Future.wait(List.generate(12, (_) => passwords.prefetch()));
      expect(fetches, 1);
      expect((await passwords.get()).value, next);
      expect(fetches, 1);
      final data = asJson(
        jsonDecode(vault.secret(BaiduPublicPasswords.cacheKey)!),
      );
      expect(data['schema'], 2);
      expect(data['source'], BaiduPublicCommandSource.pageUrl);
      var reopenedFetches = 0;
      final reopened = BaiduPublicPasswords(
        FakeHttp(),
        store: vault,
        clock: () => now,
        fetch: () async {
          reopenedFetches++;
          return '不应使用';
        },
      );
      await reopened.prefetch();
      expect(reopenedFetches, 0);
      now = now.add(const Duration(seconds: 2));
      next = '跨天密码';
      await passwords.prefetch();
      expect(fetches, 2);
      expect((await passwords.get()).value, next);
    },
  );

  for (final unavailable in [false, true]) {
    test(
      'legacy cache is rechecked on upgrade, source unavailable: $unavailable',
      () async {
        await vault.putSecret(
          BaiduPublicPasswords.cacheKey,
          encoded({
            'schema': 1,
            'source': '執心急如焚核桃仁生效',
            'value': '升级前密码',
            'fetchedAt': now.millisecondsSinceEpoch,
          }),
        );
        fail = unavailable;
        await passwords.prefetch();
        expect(fetches, 1);
        expect((await passwords.get()).value, unavailable ? '升级前密码' : next);
        if (unavailable) {
          now = now.add(const Duration(minutes: 3));
          fail = false;
          await passwords.prefetch();
          expect((await passwords.get()).value, next);
          expect(fetches, 2);
        }
      },
    );
  }

  test('background failure stays silent and uses the retry delay', () async {
    fail = true;
    await passwords.prefetch();
    await passwords.prefetch();
    expect(fetches, 1);
    await expectLater(passwords.get(), throwsA(isA<AppException>()));
    expect(fetches, 1);
    expect(vault.secret(BaiduPublicPasswords.cacheKey), isNull);
  });

  test(
    'closing cancels a stalled prefetch without waiting for its timeout',
    () async {
      final ready = Completer<void>(), result = Completer<String>();
      final service = BaiduPublicPasswords(
        FakeHttp(),
        store: vault,
        fetch: () {
          ready.complete();
          return result.future;
        },
      );
      final background = service.prefetch();
      await ready.future;
      await service.close();
      await background;
      result.complete('迟到密码');
      await Future<void>.delayed(Duration.zero);
      expect(vault.secret(BaiduPublicPasswords.cacheKey), isNull);
      await service.prefetch();
      await expectLater(service.get(), throwsA(isA<AppException>()));
    },
  );

  test(
    'a temporarily rejected source can be revalidated after the retry delay',
    () async {
      final old = await passwords.get();
      await passwords.reject(old);
      await expectLater(passwords.get(), throwsA(isA<AppException>()));
      expect(fetches, 1);
      now = now.add(const Duration(minutes: 3));
      final refreshed = await passwords.get();
      expect(refreshed.value, old.value);
      expect(refreshed, isNot(same(old)));
      expect(fetches, 2);
    },
  );

  test(
    'Gitee raw redirects stay bounded and preserve credential isolation',
    () async {
      var calls = 0;
      final http = FakeHttp((r) {
        calls++;
        expect(
          r.headers.keys.map((key) => key.toLowerCase()),
          isNot(anyElement(isIn(['cookie', 'authorization']))),
        );
        if (r.uri.host == 'gitee.com') {
          return const HttpResult(302, '', {
            'location': [
              'https://raw.giteeusercontent.com/dzys/cs/raw/master/ls.json',
            ],
          });
        }
        expect(r.uri.host, 'raw.giteeusercontent.com');
        return const HttpResult(206, '备用密码', {
          'content-type': ['text/plain'],
          'content-range': ['bytes 0-11/12'],
        });
      });
      final service = BaiduPublicPasswords(
        http,
        fetch: () => throw const AppException('UC unavailable'),
      );
      expect((await service.get()).value, '备用密码');
      expect(calls, 2);
    },
  );

  test('Gitee rejects an unrelated redirect without following it', () async {
    final http = FakeHttp(
      (_) => const HttpResult(302, '', {
        'location': ['https://other.example/password'],
      }),
    );
    final service = BaiduPublicPasswords(
      http,
      fetch: () => throw const AppException('UC unavailable'),
    );
    await expectLater(service.get(), throwsA(isA<AppException>()));
    expect(http.calls, hasLength(1));
  });

  test('an unchanged rejected UC password falls through to Gitee', () async {
    final old = await passwords.get();
    backupValue = '备用新密码';
    final fresh = await passwords.refreshRejected(old);
    expect(fresh.value, backupValue);
    expect(fetches, 2);
    expect(backupFetches, 1);
  });

  test(
    'Gitee raw fetch is bounded, uncached and carries no account headers',
    () async {
      final http = FakeHttp((r) {
        expect(r.uri.host, 'gitee.com');
        expect(r.uri.path, '/dzys/cs/raw/master/ls.json');
        expect(r.uri.queryParameters.containsKey('_t'), isTrue);
        expect(r.headers['Range'], 'bytes=0-4095');
        expect(r.headers['Cache-Control'], 'no-cache');
        expect(
          r.headers.keys.map((key) => key.toLowerCase()),
          isNot(anyElement(isIn(['cookie', 'authorization']))),
        );
        return const HttpResult(200, '{"password":"备用测试"}', {
          'content-type': ['application/json'],
        });
      });
      final service = BaiduPublicPasswords(
        http,
        fetch: () => throw const AppException('UC unavailable'),
      );
      expect((await service.get()).value, '备用测试');
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'fetch is lazy, shared by concurrent requests, and reused after restart',
    () async {
      expect(fetches, 0);
      final values = await Future.wait(
        List.generate(24, (_) => passwords.get()),
      );
      expect(fetches, 1);
      expect(values.every((value) => identical(value, values.first)), isTrue);
      final reopened = BaiduPublicPasswords(
        FakeHttp(),
        store: Vault(StateStore.memory(state.data)),
        clock: () => now,
        fetch: () => throw StateError('cache should suffice'),
      );
      expect((await reopened.get()).value, next);
      expect(fetches, 1);
    },
  );

  test(
    'midnight in Beijing refreshes even though the UTC date is unchanged',
    () async {
      final old = await passwords.get();
      now = now.add(const Duration(seconds: 2));
      next = '明日密码';
      final fresh = await passwords.get();
      expect(fresh.value, '明日密码');
      expect(fresh, isNot(same(old)));
      expect(fetches, 2);
      expect((await passwords.get()), same(fresh));
      expect(fetches, 2);
    },
  );

  test('a cache from a future clock is revalidated', () async {
    await passwords.get();
    now = now.subtract(const Duration(hours: 1));
    next = '校时密码';
    expect((await passwords.get()).value, next);
    expect(fetches, 2);
  });

  test(
    'failed daily updates preserve the previous cache and back off briefly',
    () async {
      final old = await passwords.get();
      final saved = vault.secret(BaiduPublicPasswords.cacheKey);
      now = now.add(const Duration(seconds: 2));
      fail = true;
      expect(await passwords.get(), same(old));
      expect(fetches, 2);
      expect(vault.secret(BaiduPublicPasswords.cacheKey), saved);
      await Future.wait(List.generate(10, (_) => passwords.get()));
      expect(fetches, 2);
      now = now.add(const Duration(minutes: 3));
      fail = false;
      next = '恢复密码';
      expect((await passwords.get()).value, next);
      expect(fetches, 3);
    },
  );

  test('malformed new content cannot replace a usable password', () async {
    final old = await passwords.get();
    final saved = vault.secret(BaiduPublicPasswords.cacheKey);
    now = now.add(const Duration(days: 1));
    next = 'not-a-password';
    expect(await passwords.get(), same(old));
    expect(vault.secret(BaiduPublicPasswords.cacheKey), saved);
  });

  test(
    'a missing password reports an account-route alternative without leaking source errors',
    () async {
      fail = true;
      for (var i = 0; i < 2; i++) {
        await expectLater(
          passwords.get(),
          throwsA(
            allOf(
              isA<AppException>()
                  .having((e) => e.message, 'fallback', contains('账号下载'))
                  .having(
                    (e) => e.message,
                    'no credentials',
                    isNot(contains('private-account')),
                  ),
              isNot(isA<AccountLoginRequired>()),
            ),
          ),
        );
      }
      expect(fetches, 1);
      expect(vault.secret(BaiduPublicPasswords.cacheKey), isNull);
    },
  );

  test('a corrupt optional cache does not stop fetching', () async {
    await vault.putSecret(BaiduPublicPasswords.cacheKey, '{broken JSON');
    expect((await passwords.get()).value, next);
  });

  test(
    'cache is device-wide and does not change accounts or their settings',
    () async {
      final original = Credential('账号', {
        'primary': '__pus=private-account-cookie',
      }, updatedAt: 1);
      await vault.putCredential(CloudPlatform.uc, original);
      await state.change(Vault.migrateDraft);
      final before = encoded(state.data.obj('cloudAccounts'));
      await vault.withAccount(CloudPlatform.uc, null, passwords.get);
      final cached = vault.secret(BaiduPublicPasswords.cacheKey);
      expect(cached, isNotNull);
      expect(vault.credential(CloudPlatform.uc)!.sameAs(original), isTrue);
      expect(encoded(state.data.obj('cloudAccounts')), before);
      expect(state.data['downloads'], isNull);
      expect(state.data['settings'], isNull);
      await vault.withAccount(CloudPlatform.uc, null, () async {
        expect(vault.secret(BaiduPublicPasswords.cacheKey), cached);
      });
    },
  );

  test(
    'simultaneous stale password errors cause one refresh and late errors cannot undo it',
    () async {
      final old = await passwords.get();
      next = '更新密码';
      final fresh = await Future.wait(
        List.generate(20, (_) => passwords.refreshRejected(old)),
      );
      expect(fetches, 2);
      expect(fresh.every((item) => item.value == next), isTrue);
      await passwords.reject(old);
      expect(await passwords.get(), same(fresh.first));
      expect(await passwords.refreshRejected(old), same(fresh.first));
      expect(fetches, 2);
    },
  );

  test(
    'a rejected password is not used as fallback and its invalidation survives restart',
    () async {
      final old = await passwords.get();
      fail = true;
      await expectLater(
        passwords.refreshRejected(old),
        throwsA(isA<AppException>()),
      );
      await expectLater(passwords.get(), throwsA(isA<AppException>()));
      expect(fetches, 2);
      final reopened = BaiduPublicPasswords(
        FakeHttp(),
        store: vault,
        clock: () => now,
        fetch: () async => '重启新密码',
      );
      expect((await reopened.get()).value, '重启新密码');
    },
  );

  test('an unwritable optional cache does not block parsing', () async {
    final service = BaiduPublicPasswords(
      FakeHttp(),
      store: _UnwritableVault(state),
      fetch: () async => '内存密码',
    );
    final value = await service.get();
    expect(value.value, '内存密码');
    expect(await service.get(), same(value));
  });

  test(
    'cancelling the first caller does not cancel other password waiters',
    () async {
      final ready = Completer<void>(), result = Completer<String>();
      final scope = RequestScope();
      var changed = false, guestSignals = 0;
      final http = RetryingJsonHttp(
        FakeHttp((_) => const HttpResult(200, 'ok')),
      );
      final service = BaiduPublicPasswords(
        http,
        fetch: () async {
          ready.complete();
          final value = await result.future;
          RequestScope.checkpoint();
          DownloadRequestContext.current?.onGuestDownload?.call();
          await http.get('https://fixture.invalid/password');
          return value;
        },
      );
      final first = scope.run(
        () => RequestScope.guarded(
          () =>
              ReadRetryScope(
                retries: 0,
                checkpoint: () {
                  if (changed) {
                    throw const AppException('previous download guard');
                  }
                },
              ).run(
                () => DownloadRequestContext(
                  id: 'first-download',
                  retries: 0,
                  onGuestDownload: () => guestSignals++,
                ).run(service.get),
              ),
          () {
            if (changed) throw const AppException('account changed');
          },
        ),
      );
      final cancelled = expectLater(first, throwsA(isA<AppException>()));
      await ready.future;
      final second = service.get();
      changed = true;
      scope.cancel();
      await cancelled;
      result.complete('共享密码');
      expect((await second).value, '共享密码');
      expect(guestSignals, 0);
      expect((await service.get()).value, '共享密码');
    },
  );

  testWidgets(
    'a hung lookup times out and a late result cannot overwrite the cache',
    (tester) async {
      final result = Completer<String>();
      final service = BaiduPublicPasswords(
        FakeHttp(),
        store: vault,
        fetch: () => result.future,
      );
      final pending = expectLater(service.get(), throwsA(isA<AppException>()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 46));
      await pending;
      result.complete('超时密码');
      await tester.pump();
      expect(vault.secret(BaiduPublicPasswords.cacheKey), isNull);
    },
  );

  test(
    'the complete UC source path reads only a prefix with guest cookies',
    () async {
      await vault.putCredential(
        CloudPlatform.uc,
        Credential('UC', {
          'primary': '__pus=private-account-cookie',
        }, updatedAt: 1),
      );
      final source = _UcSource();
      var signals = 0;
      final value = await DownloadRequestContext(
        id: 'baidu-file',
        retries: 0,
        onGuestDownload: () => signals++,
      ).run(() => source.passwords(store: vault).get());
      expect(value.value, '测试密码');
      expect(signals, 0);
      expect(source.requests, hasLength(7));
      expect(source.requests.last.headers['Range'], 'bytes=0-4095');
      expect(
        vault.credential(CloudPlatform.uc)!.primary,
        '__pus=private-account-cookie',
      );
    },
  );

  for (final problem in ['html', 'range', 'redirect', 'ambiguous']) {
    test('UC source $problem cannot supply a password', () async {
      final source = _UcSource();
      switch (problem) {
        case 'html':
          source.contentType = 'text/html';
        case 'range':
          source.range = 'bytes 4096-8191/345196';
        case 'redirect':
          source.status = 302;
        case 'ambiguous':
          source.ambiguous = true;
      }
      await expectLater(source.passwords().get(), throwsA(isA<AppException>()));
      expect(source.requests, hasLength(problem == 'ambiguous' ? 4 : 7));
    });
  }

  test(
    'each new day resolves the newly published command before reading the file',
    () async {
      final source = _UcSource();
      final service = source.passwords(store: vault, clock: () => now);
      await service.prefetch();
      final oldCommand = source.command;
      now = now.add(const Duration(seconds: 2));
      source.command = '執下一天碧螺春生效';
      source.prefix = '======明日不同密码======\n正文';
      await service.prefetch();
      expect((await service.get()).value, '明日不同密码');
      expect(
        source.requests.where((r) => r.uri.host == 'www.yuque.com'),
        hasLength(2),
      );
      expect(
        source.requests
            .where((r) => r.uri.host == 'utoken2.uc.cn')
            .map((r) => r.json.str('clipboard')),
        [oldCommand, source.command],
      );
    },
  );

  test(
    'an unavailable command page goes to Gitee without requesting an old command',
    () async {
      final source = _UcSource()..pageUnavailable = true;
      final service = BaiduPublicPasswords(
        FakeHttp(source.respond),
        fetchBackup: () async => '页面故障备用密码',
      );
      await service.prefetch();
      expect((await service.get()).source, BaiduPublicPasswordSource.gitee);
      expect(source.requests, hasLength(1));
      expect(source.requests.single.uri.host, 'www.yuque.com');
    },
  );

  for (final cache in ['empty', 'guest', 'authenticated']) {
    test(
      'public parsing requires an explicit grant with $cache cache',
      () async {
        if (cache == 'guest') await passwords.get();
        if (cache == 'authenticated') await passwords.authenticated();
        final readsBefore = fetches;
        final http = FakeHttp(BaiduPublicFixture().respond);
        final parser = BaiduPublicParser(http, passwords: passwords);
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            parser.openShare(BaiduPublicFixture().link),
            throwsA(isA<ParserPasswordRequired>()),
          );
        }
        expect(http.calls, isEmpty);
        expect(fetches, readsBefore);
        expect(backupFetches, 0);
      },
    );
  }
}
