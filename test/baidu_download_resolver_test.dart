import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/baidu_download_resolver.dart';
import 'package:asterlink/data/providers/baidu_resolved_link.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

const _device = {'id': '0123456789ABCDEF0123456789ABCDEF|0'};
const _url = 'https://fixture.baidupcs.com/file';
const _hosts = {'pan.baidu.com', 'passport.baidu.com', 'd.pcs.baidu.com'};

Future<BaiduResolvedLink> _resolve(
  BaiduDownloadResolver resolver, {
  int fileSize = 0,
}) => resolver.resolve(
  cookie: 'BDUSS=fixture',
  path: '/original.bin',
  fileId: '123',
  appId: '250528',
  device: _device,
  fileSize: fileSize,
);

HttpResult _respond(RecordedRequest r, String route) {
  expect(_hosts, contains(r.uri.host));
  expect(r.headers['Cookie'], 'BDUSS=fixture');
  switch (r.uri.path) {
    case '/rest/2.0/xpan/nas':
      return jsonResponse({'errno': 0, 'vip_type': 0});
    case '/v2/sapi/center/getuinfo':
      if (route != 'preview') return const HttpResult(503, 'unavailable');
      return jsonResponse({'errno': 0, 'uid': '123456789'});
    case '/api/report/user':
      return jsonResponse({
        'errno': 0,
        'uinfo': 'RLs/VygyH/SSzONO6GIxAXLEsLVtm3s=',
      });
    case '/rest/2.0/pcs/file':
      expect(r.uri.queryParameters['path'], '/original.bin');
      expect(r.uri.queryParameters['use'], route == 'preview' ? '1' : isNull);
      if (route == 'metadata' || route == 'failure') {
        return const HttpResult(503, 'unavailable');
      }
      return jsonResponse({
        'urls': [
          {'url': _url, 'encrypt': 0},
        ],
      });
    case '/api/filemetas':
      if (route == 'failure') return const HttpResult(503, 'unavailable');
      return jsonResponse({
        'errno': 0,
        'info': [
          {'fs_id': '123', 'dlink': _url},
        ],
      });
    default:
      throw StateError('Unexpected request: ${r.uri.path}');
  }
}

void main() {
  const limit = 300 * 1024 * 1024;
  for (final size in [
    -1,
    0,
    1,
    limit - 1,
    limit,
    limit + 1,
    8 * 1024 * 1024 * 1024,
  ]) {
    for (final route in ['preview', 'ordinary', 'metadata', 'failure']) {
      test('$size bytes: $route uses only built-in Baidu APIs', () async {
        final http = FakeHttp((r) => _respond(r, route));
        final future = _resolve(BaiduDownloadResolver(http), fileSize: size);
        if (route == 'failure') {
          await expectLater(future, throwsA(isA<HttpRequestFailure>()));
        } else {
          final result = await future;
          expect(result.url, _url);
          expect(
            result.profile,
            route == 'preview' ? 'baidu_preview' : 'baidu',
          );
        }
        expect(http.calls.map((r) => r.uri.host), everyElement(isIn(_hosts)));
        expect(http.calls, hasLength(route == 'ordinary' ? 3 : 4));
      });
    }
  }

  for (final failAt in [
    '/rest/2.0/xpan/nas',
    '/v2/sapi/center/getuinfo',
    '/api/report/user',
    '/rest/2.0/pcs/file',
  ]) {
    test('Expired account at $failAt stops further resolution', () async {
      final http = FakeHttp(
        (r) => r.uri.path == failAt
            ? jsonResponse({'errno': -6})
            : _respond(r, 'preview'),
      );
      await expectLater(
        _resolve(BaiduDownloadResolver(http)),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls.last.uri.path, failAt);
      expect(http.calls.map((r) => r.uri.host), everyElement(isIn(_hosts)));
    });
  }

  for (final guard in ['cancel', 'account']) {
    for (final succeeds in [true, false]) {
      test(
        '$guard during local lookup rejects late ${succeeds ? 'success' : 'failure'}',
        () async {
          final scope = RequestScope();
          var changed = false, calls = 0;
          const changedError = AppException('account changed');
          final resolver = BaiduDownloadResolver(
            FakeHttp(),
            local: _lookup(() async {
              calls++;
              if (guard == 'account') {
                changed = true;
              } else {
                scope.cancel();
              }
              if (!succeeds) throw const AccountLoginRequired('late failure');
              return const BaiduResolvedLink(url: _url, preview: true);
            }),
          );
          await expectLater(
            scope.run(
              () => RequestScope.guarded(() => _resolve(resolver), () {
                if (changed) throw changedError;
              }),
            ),
            guard == 'account'
                ? throwsA(same(changedError))
                : throwsA(
                    isA<AppException>().having(
                      (e) => e.message,
                      'message',
                      '请求已取消',
                    ),
                  ),
          );
          expect(calls, 1);
        },
      );
    }
  }
  test('Already cancelled request does not begin local resolution', () async {
    final scope = RequestScope()..cancel();
    final http = FakeHttp();
    await expectLater(
      scope.run(() => _resolve(BaiduDownloadResolver(http))),
      throwsA(isA<AppException>().having((e) => e.message, 'message', '请求已取消')),
    );
    expect(http.calls, isEmpty);
  });

  for (final retries in [0, 2]) {
    test('Local reads honor the bounded retry budget ($retries)', () async {
      var attempts = 0;
      final delays = <Duration>[];
      final scope = ReadRetryScope(
        retries: retries,
        checkpoint: RequestScope.checkpoint,
        wait: (d) async => delays.add(d),
      );
      final raw = FakeHttp((r) {
        if (r.uri.host == 'd.pcs.baidu.com' && ++attempts < 3) {
          return const HttpResult(503, 'unavailable');
        }
        return _respond(r, retries == 0 ? 'metadata' : 'preview');
      });
      final result = await scope.run(
        () => _resolve(BaiduDownloadResolver(RetryingJsonHttp(raw))),
      );
      expect(result.url, _url);
      expect(result.profile, retries == 0 ? 'baidu' : 'baidu_preview');
      expect(attempts, retries == 0 ? 1 : 3);
      expect(
        delays,
        retries == 0
            ? isEmpty
            : [const Duration(seconds: 2), const Duration(seconds: 5)],
      );
    });
  }
  test(
    'Cancellation during local retry prevents any further request',
    () async {
      final request = RequestScope();
      final raw = FakeHttp((r) => const HttpResult(503, 'unavailable'));
      final retries = ReadRetryScope(
        retries: 2,
        checkpoint: RequestScope.checkpoint,
        wait: (_) async => request.cancel(),
      );
      await expectLater(
        request.run(
          () => retries.run(
            () => _resolve(BaiduDownloadResolver(RetryingJsonHttp(raw))),
          ),
        ),
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '请求已取消'),
        ),
      );
      expect(raw.calls, hasLength(1));
    },
  );
}

BaiduLinkLookup _lookup(Future<BaiduResolvedLink> Function() action) =>
    ({
      required cookie,
      required path,
      required fileId,
      required appId,
      required device,
    }) {
      expect(cookie, 'BDUSS=fixture');
      expect(path, '/original.bin');
      expect(fileId, '123');
      expect(appId, '250528');
      expect(device, _device);
      return action();
    };
