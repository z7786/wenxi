import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/baidu_download_resolver.dart';
import 'package:asterlink/data/providers/baidu_link_service.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

Future<BaiduResolvedLink> _resolve(BaiduDownloadResolver resolver) =>
    resolver.resolve(
      cookie: 'BDUSS=fixture',
      path: '/original.bin',
      fileId: '123',
      appId: '250528',
      device: const {'id': 'fixture'},
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
