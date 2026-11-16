import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/baidu_download_resolver.dart';
import 'package:asterlink/data/providers/baidu_link_service.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

Future<BaiduResolvedLink> _resolve(
  BaiduDownloadResolver resolver, {
  int fileSize = 0,
}) => resolver.resolve(
  cookie: 'BDUSS=fixture',
  path: '/original.bin',
  fileId: '123',
  appId: '250528',
  device: const {'id': 'fixture'},
  fileSize: fileSize,
);

void main() {
  const direct = BaiduResolvedLink(
    url: 'https://fixture.baidupcs.com/direct',
    profile: 'baidu_direct',
    headers: {
      'Host': 'fixture_route.baidu-int.com',
      'User-Agent': 'netdisk',
      'Accept-Encoding': 'identity',
    },
  );
  const local = BaiduResolvedLink(
    url: 'https://fixture.baidupcs.com/preview',
    preview: true,
  );
  group('Small ordinary file routing', () {
    const limit = 300 * 1024 * 1024;
    for (final size in [-1, 0, 1, limit - 1, limit, limit + 1]) {
      test('Route order for $size bytes', () async {
        final order = <String>[];
        final resolver = BaiduDownloadResolver(
          FakeHttp((r) {
            order.add('probe');
            expect(r.url, direct.url);
            expect(r.headers['Cookie'], isNull);
            return const HttpResult(206, 'x', {
              'content-range': ['bytes 0-0/123'],
            });
          }),
          relay: _lookup(() async {
            order.add('relay');
            return direct;
          }),
          preview: _lookup(() async {
            order.add('preview');
            return local;
          }),
        );
        final small = size > 0 && size < limit;
        expect(
          await _resolve(resolver, fileSize: size),
          same(small ? local : direct),
        );
        expect(order, small ? ['preview'] : ['relay', 'probe']);
      });
    }
    for (final failure in [
      const HttpRequestFailure('timeout', kind: 'receiveTimeout'),
      const HttpRequestFailure(
        'unavailable',
        kind: 'baidu_local_http',
        status: 503,
      ),
      const AppException('preview rejected'),
    ]) {
      test('Preferred preview failure falls back to relay: $failure', () async {
        final order = <String>[];
        final resolver = BaiduDownloadResolver(
          FakeHttp((_) {
            order.add('probe');
            return const HttpResult(206, 'x', {
              'content-range': ['bytes 0-0/123'],
            });
          }),
          relay: _lookup(() async {
            order.add('relay');
            return direct;
          }),
          preview: _lookup(() async {
            order.add('preview');
            throw failure;
          }),
        );
        expect(await _resolve(resolver, fileSize: 42), same(direct));
        expect(order, ['preview', 'relay', 'probe']);
      });
    }
    test(
      'Ordinary preview fallback does not bypass the preferred relay',
      () async {
        var relays = 0;
        final resolver = BaiduDownloadResolver(
          FakeHttp(
            (_) => const HttpResult(206, 'x', {
              'content-range': ['bytes 0-0/123'],
            }),
          ),
          relay: _lookup(() async {
            relays++;
            return direct;
          }),
          preview: _lookup(
            () async => const BaiduResolvedLink(
              url: 'https://fixture.baidupcs.com/ordinary',
            ),
          ),
        );
        expect(await _resolve(resolver, fileSize: 42), same(direct));
        expect(relays, 1);
      },
    );
    test('Expired local account remains a login failure', () async {
      var relays = 0;
      final resolver = BaiduDownloadResolver(
        FakeHttp(),
        relay: _lookup(() async {
          relays++;
          return direct;
        }),
        preview: _lookup(
          () async => throw const AccountLoginRequired('expired'),
        ),
      );
      await expectLater(
        _resolve(resolver, fileSize: 42),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(relays, 0);
    });
    for (final guard in ['cancel', 'account', 'late-cancel']) {
      test(
        '$guard during preview prevents relay or stale URL publication',
        () async {
          final scope = RequestScope();
          var changed = false, relays = 0;
          final http = FakeHttp();
          final resolver = BaiduDownloadResolver(
            http,
            relay: _lookup(() async {
              relays++;
              return direct;
            }),
            preview: _lookup(() async {
              if (guard == 'account') {
                changed = true;
              } else {
                scope.cancel();
              }
              if (guard == 'late-cancel') return local;
              throw const AppException('preview interrupted');
            }),
          );
          await expectLater(
            scope.run(
              () => RequestScope.guarded(
                () => _resolve(resolver, fileSize: 42),
                () => require(!changed, 'account changed'),
              ),
            ),
            throwsA(isA<AppException>()),
          );
          expect(relays, 0);
          expect(http.calls, isEmpty);
        },
      );
    }
    test(
      'Preview and relay first attempts preserve the final retry budget',
      () async {
        var previewCalls = 0, relayCalls = 0;
        final delays = <Duration>[];
        final scope = ReadRetryScope(
          retries: 2,
          checkpoint: RequestScope.checkpoint,
          wait: (delay) async => delays.add(delay),
        );
        final http = RetryingJsonHttp(
          RetryingJsonHttp(
            FakeHttp((r) {
              if (r.uri.host == 'preview.test') {
                return HttpResult(++previewCalls < 3 ? 503 : 200, '{}');
              }
              relayCalls++;
              return const HttpResult(503, '{}');
            }),
          ),
        );
        final resolver = BaiduDownloadResolver(
          http,
          relay: _lookup(() async {
            expect(ReadRetryScope.current, isNull);
            require(
              (await http.get('https://relay.test/read')).successful,
              'offline',
            );
            return direct;
          }),
          preview: _lookup(() async {
            expect(
              ReadRetryScope.current,
              previewCalls == 0 ? isNull : same(scope),
            );
            require(
              (await http.get('https://preview.test/read')).successful,
              'offline',
            );
            return local;
          }),
        );
        expect(
          await scope.run(() => _resolve(resolver, fileSize: 42)),
          same(local),
        );
        expect(previewCalls, 3);
        expect(relayCalls, 1);
        expect(delays, [const Duration(seconds: 2)]);
      },
    );
  });
  for (final failAtRelay in [true, false]) {
    for (final timeout in [true, false]) {
      test(
        '${failAtRelay ? 'Relay' : 'CDN'} ${timeout ? 'timeout' : '503'} falls back once and preserves preview retries',
        () async {
          var firstRouteCalls = 0, previewCalls = 0;
          final delays = <Duration>[];
          final scope = ReadRetryScope(
            retries: 64,
            checkpoint: RequestScope.checkpoint,
            wait: (delay) async => delays.add(delay),
          );
          final http = RetryingJsonHttp(
            RetryingJsonHttp(
              FakeHttp((r) {
                if (r.uri.host == 'preview.test') {
                  return HttpResult(++previewCalls == 1 ? 503 : 200, '{}');
                }
                firstRouteCalls++;
                if (timeout) {
                  throw const HttpRequestFailure(
                    'timeout',
                    kind: 'receiveTimeout',
                    retryable: true,
                  );
                }
                return const HttpResult(503, 'unavailable');
              }),
            ),
          );
          final resolver = BaiduDownloadResolver(
            http,
            relay:
                ({
                  required cookie,
                  required path,
                  required fileId,
                  required appId,
                  required device,
                }) async {
                  if (failAtRelay) {
                    final response = await http.get('https://relay.test/read');
                    require(response.successful, 'unavailable');
                  }
                  return direct;
                },
            preview:
                ({
                  required cookie,
                  required path,
                  required fileId,
                  required appId,
                  required device,
                }) async {
                  expect(ReadRetryScope.current, same(scope));
                  final response = await http.get('https://preview.test/read');
                  require(response.successful, 'unavailable');
                  return local;
                },
          );
          expect(await scope.run(() => _resolve(resolver)), same(local));
          expect(firstRouteCalls, 1);
          expect(previewCalls, 2);
          expect(delays, [const Duration(seconds: 2)]);
        },
      );
    }
  }
  test('Account change guard stops before fallback', () async {
    var changed = false, previews = 0;
    final resolver = BaiduDownloadResolver(
      FakeHttp(),
      relay:
          ({
            required cookie,
            required path,
            required fileId,
            required appId,
            required device,
          }) async {
            changed = true;
            throw const AppException('offline');
          },
      preview:
          ({
            required cookie,
            required path,
            required fileId,
            required appId,
            required device,
          }) async {
            previews++;
            return local;
          },
    );
    await expectLater(
      RequestScope.guarded(() => _resolve(resolver), () {
        require(!changed, 'account changed');
      }),
      throwsA(isA<AppException>()),
    );
    expect(previews, 0);
  });
  test(
    'Available relay is probed without cookies and skips local preview',
    () async {
      var previews = 0;
      final http = FakeHttp((r) {
        expect(r.url, direct.url);
        expect(r.headers['Cookie'], isNull);
        expect(r.headers['Range'], 'bytes=0-0');
        return const HttpResult(206, 'x', {
          'content-range': ['bytes 0-0/123'],
        });
      });
      final resolver = BaiduDownloadResolver(
        http,
        relay:
            ({
              required cookie,
              required path,
              required fileId,
              required appId,
              required device,
            }) async => direct,
        preview:
            ({
              required cookie,
              required path,
              required fileId,
              required appId,
              required device,
            }) async {
              previews++;
              return local;
            },
      );
      expect(await _resolve(resolver), same(direct));
      expect(previews, 0);
    },
  );
  for (final failure in [
    const HttpRequestFailure('offline', kind: 'baidu_service_upstream'),
    const HttpRequestFailure('timeout', kind: 'receiveTimeout'),
    const AccountLoginRequired('upstream rejected session'),
    const AppException('invalid encrypted response'),
  ]) {
    test(
      'Relay failure falls back on device: ${failure.runtimeType}',
      () async {
        var previews = 0;
        final http = FakeHttp();
        final resolver = BaiduDownloadResolver(
          http,
          relay:
              ({
                required cookie,
                required path,
                required fileId,
                required appId,
                required device,
              }) async => throw failure,
          preview:
              ({
                required cookie,
                required path,
                required fileId,
                required appId,
                required device,
              }) async {
                expect(cookie, 'BDUSS=fixture');
                expect(path, '/original.bin');
                expect(fileId, '123');
                previews++;
                return local;
              },
        );
        expect(await _resolve(resolver), same(local));
        expect(previews, 1);
        expect(http.calls, isEmpty);
      },
    );
  }
  for (final probe in [
    const HttpResult(403, 'denied'),
    const HttpResult(200, 'wrong range'),
    const HttpResult(206, 'x', {
      'content-range': ['bytes 1-1/123'],
    }),
  ]) {
    test(
      'Unusable relay CDN response triggers local preview: ${probe.status}/${probe.header('content-range')}',
      () async {
        final resolver = BaiduDownloadResolver(
          FakeHttp((_) => probe),
          relay:
              ({
                required cookie,
                required path,
                required fileId,
                required appId,
                required device,
              }) async => direct,
          preview:
              ({
                required cookie,
                required path,
                required fileId,
                required appId,
                required device,
              }) async => local,
        );
        expect(await _resolve(resolver), same(local));
      },
    );
  }
  test('User cancellation stops before fallback', () async {
    final scope = RequestScope();
    var previews = 0;
    final resolver = BaiduDownloadResolver(
      FakeHttp(),
      relay:
          ({
            required cookie,
            required path,
            required fileId,
            required appId,
            required device,
          }) async {
            scope.cancel();
            throw const AppException('cancelled');
          },
      preview:
          ({
            required cookie,
            required path,
            required fileId,
            required appId,
            required device,
          }) async {
            previews++;
            return local;
          },
    );
    await expectLater(
      scope.run(() => _resolve(resolver)),
      throwsA(isA<AppException>()),
    );
    expect(previews, 0);
  });
  test(
    'Local login failure after relay failure remains a login failure',
    () async {
      final resolver = BaiduDownloadResolver(
        FakeHttp(),
        relay:
            ({
              required cookie,
              required path,
              required fileId,
              required appId,
              required device,
            }) async => throw const AppException('offline'),
        preview:
            ({
              required cookie,
              required path,
              required fileId,
              required appId,
              required device,
            }) async => throw const AccountLoginRequired('expired'),
      );
      await expectLater(
        _resolve(resolver),
        throwsA(isA<AccountLoginRequired>()),
      );
    },
  );
}

BaiduLinkLookup _lookup(Future<BaiduResolvedLink> Function() action) =>
    ({
      required String cookie,
      required String path,
      required String fileId,
      required String appId,
      required Json device,
    }) {
      expect(cookie, 'BDUSS=fixture');
      expect(path, '/original.bin');
      expect(fileId, '123');
      expect(appId, '250528');
      expect(device, const {'id': 'fixture'});
      return action();
    };
