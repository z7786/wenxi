import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/aliyun_playback.dart';
import 'package:asterlink/data/providers/token_session.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const _platform = CloudPlatform.aliyun;
const _openAccess = 'fixture-open-access-0123456789';
const _nextAccess = 'next-open-access-token-0123456789';
const _openRefresh = 'fixture-open-refresh-0123456789';
const _oauthCallback = 'https://api.oplist.org/alicloud/callback';
const _previewPath = '/adrive/v1.0/openFile/getVideoPreviewPlayInfo';

Json _tokens({String access = _openAccess, String user = 'user-1'}) => {
  'access_token': access,
  'refresh_token': _openRefresh,
  'token_type': 'Bearer',
  'expires_in': 7200,
  'user_id': user,
};

HttpResult _exchange(Json tokens, {bool escaped = false}) {
  var fragment = base64.encode(utf8.encode(encoded(tokens)));
  if (escaped) {
    fragment = Uri.encodeComponent(
      fragment.replaceAll('+', '-').replaceAll('/', '_'),
    );
  }
  return HttpResult(302, '', {
    'location': ['https://doc.oplist.org/#$fragment'],
  });
}

HttpResult _bootstrap({String state = '', String redirect = _oauthCallback}) =>
    jsonResponse({
      'text': query('https://openapi.aliyundrive.com/oauth/authorize', {
        'client_id': 'fixture-client',
        'redirect_uri': redirect,
        'response_type': 'code',
        if (state.isNotEmpty) 'state': state,
      }),
    });

HttpResult _reply(
  RecordedRequest request, {
  String access = _openAccess,
  String state = '',
}) => switch (request.uri.path) {
  '/alicloud/requests' => _bootstrap(state: state),
  '/oauth/users/authorize' => jsonResponse({
    'redirectUri': query(_oauthCallback, {
      'code': 'fixture-code',
      if (state.isNotEmpty) 'state': state,
    }),
  }),
  '/alicloud/callback' => _exchange(_tokens(access: access)),
  _previewPath => jsonResponse({}),
  _ => throw StateError('Unexpected request ${request.uri.path}'),
};

AliyunPlaybackApi _api(
  JsonHttp http,
  TokenSessions sessions, {
  Future<void> Function(TokenSession)? renew,
  Future<void> Function(Duration)? wait,
}) => AliyunPlaybackApi(
  http,
  sessions,
  renew: renew ?? (_) async => throw StateError('Unexpected login refresh'),
  userAgent: 'fixture-agent',
  wait: wait ?? (_) async {},
);

class _RedirectHttp extends FakeHttp {
  _RedirectHttp(super.respond);
  final redirects = <bool>[];
  final reads = <bool>[];

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) {
    redirects.add(followRedirects);
    reads.add(JsonHttp.isReadRequest(method, url));
    return super.request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    );
  }
}

void main() {
  test(
    'OpenList exchanges only an authorization code and saves separate tokens',
    () async {
      final vault = await tokenVault(_platform);
      final before = vault.credential(_platform)!;
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final http = _RedirectHttp((r) => _reply(r, state: 'fixture-state'));
      await _api(http, sessions).request(
        sessions.open(before),
        'openFile/getVideoPreviewPlayInfo',
        {'drive_id': 'resource', 'file_id': 'file-1'},
      );

      expect(http.calls.map((r) => r.uri.path), [
        '/alicloud/requests',
        '/oauth/users/authorize',
        '/alicloud/callback',
        _previewPath,
      ]);
      final authorization = http.calls[1];
      expect(authorization.uri.host, 'open.aliyundrive.com');
      expect(authorization.uri.queryParameters, {
        'client_id': 'fixture-client',
        'redirect_uri': _oauthCallback,
        'scope': AliyunPlaybackApi.scope,
        'state': 'fixture-state',
        'response_type': 'code',
      });
      expect(authorization.json, {
        'authorize': 1,
        'scope': AliyunPlaybackApi.scope,
      });
      expect(authorization.headers['Authorization'], 'Bearer $accessToken');
      expect(authorization.headers['X-Signature'], isNull);
      for (final request in http.calls.where(
        (r) => r.uri.host == 'api.oplist.org',
      )) {
        expect(request.headers['Authorization'], isNull);
        expect(request.body, isNull);
        final wire = encoded({'url': request.url, 'headers': request.headers});
        expect(wire, isNot(contains(accessToken)));
        expect(wire, isNot(contains(refreshToken)));
        expect(wire, isNot(contains(_openRefresh)));
      }
      expect(http.calls[2].uri.queryParameters, {'code': 'fixture-code'});
      expect(
        http.calls[2].headers['Cookie'],
        'server_use=true; driver_txt=alicloud_go',
      );
      expect(http.calls.last.headers['Authorization'], 'Bearer $_openAccess');
      expect(http.calls.last.headers['X-Device-Id'], isNull);
      expect(http.redirects, everyElement(isFalse));
      expect(http.reads, [true, false, false, true]);
      final after = vault.credential(_platform)!;
      expect(after.updatedAt, before.updatedAt);
      expect(after.primary, before.primary);
      expect(after.field('accessToken'), accessToken);
      expect(after.field('refreshToken'), refreshToken);
      expect(after.field('openAccessToken'), _openAccess);
      expect(after.field('openRefreshToken'), _openRefresh);
      expect(after.field('openExpiresAt'), '${tokenClock + 7200000}');
      expect(after.field('openUserId'), 'user-1');
    },
  );

  test('a fresh saved OpenToken avoids an OAuth exchange', () async {
    final vault = await tokenVault(
      _platform,
      tokenCredential(
        _platform,
        fields: {
          'openAccessToken': _openAccess,
          'openExpiresAt': '${tokenClock + 3600000}',
        },
      ),
    );
    final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
    final http = FakeHttp((r) => _reply(r));
    final api = _api(http, sessions);
    for (var i = 0; i < 2; i++) {
      await api.request(
        sessions.open(vault.credential(_platform)!),
        'openFile/getVideoPreviewPlayInfo',
        {},
      );
    }
    expect(http.calls.map((r) => r.uri.path), [_previewPath, _previewPath]);
  });

  test(
    'a cached OpenToken for another user is replaced using the current login',
    () async {
      final vault = await tokenVault(
        _platform,
        tokenCredential(
          _platform,
          fields: {
            'openAccessToken': _nextAccess,
            'openExpiresAt': '${tokenClock + 3600000}',
            'openUserId': 'another-user',
          },
        ),
      );
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final http = FakeHttp((r) => _reply(r));
      await _api(
        http,
        sessions,
      ).fresh(sessions.open(vault.credential(_platform)!));
      expect(
        http.calls.where((r) => r.uri.path == '/alicloud/callback'),
        hasLength(1),
      );
      expect(
        vault.credential(_platform)!.field('openAccessToken'),
        _openAccess,
      );
      expect(vault.credential(_platform)!.field('openUserId'), 'user-1');
    },
  );

  test(
    'OpenToken renewal is serialized across concurrent playback requests',
    () async {
      final vault = await tokenVault(
        _platform,
        tokenCredential(
          _platform,
          fields: {
            'openAccessToken': _nextAccess,
            'openExpiresAt': '${tokenClock + 119000}',
          },
        ),
      );
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final entered = Completer<void>(), release = Completer<void>();
      final http = FakeHttp((r) async {
        if (r.uri.path == '/alicloud/requests') {
          entered.complete();
          await release.future;
        }
        return _reply(r);
      });
      final api = _api(http, sessions);
      final owner = vault.credential(_platform)!;
      final pending = [
        api.request(
          sessions.open(owner),
          'openFile/getVideoPreviewPlayInfo',
          {},
        ),
        api.request(
          sessions.open(owner),
          'openFile/getVideoPreviewPlayInfo',
          {},
        ),
      ];
      await entered.future;
      release.complete();
      await Future.wait(pending);
      expect(
        http.calls.where((r) => r.uri.path == '/alicloud/requests'),
        hasLength(1),
      );
      expect(
        http.calls.where((r) => r.uri.path == '/alicloud/callback'),
        hasLength(1),
      );
      expect(http.calls.where((r) => r.uri.path == _previewPath), hasLength(2));
    },
  );

  test(
    'an expired ordinary login refreshes before open-platform authorization',
    () async {
      final vault = await tokenVault(
        _platform,
        tokenCredential(_platform, expired: true),
      );
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      var refreshes = 0;
      final http = FakeHttp((r) {
        if (r.uri.path == '/oauth/users/authorize') {
          expect(r.headers['Authorization'], 'Bearer $renewedAccess');
        }
        return _reply(r);
      });
      final api = _api(
        http,
        sessions,
        renew: (session) async {
          refreshes++;
          await sessions.update(session, {
            'primary': renewedRefresh,
            'accessToken': renewedAccess,
            'refreshToken': renewedRefresh,
            'expiresAt': '${tokenClock + 7200000}',
          });
        },
      );
      await api.fresh(sessions.open(vault.credential(_platform)!));
      expect(refreshes, 1);
      expect(
        vault.credential(_platform)!.field('refreshToken'),
        renewedRefresh,
      );
      expect(
        vault.credential(_platform)!.field('openRefreshToken'),
        _openRefresh,
      );
    },
  );

  test(
    'a rejected ordinary access token refreshes once during authorization',
    () async {
      final vault = await tokenVault(_platform);
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      var authorizations = 0, refreshes = 0;
      final http = FakeHttp((r) {
        if (r.uri.path == '/oauth/users/authorize') {
          authorizations++;
          if (authorizations == 1) {
            return jsonResponse({'code': 'AccessTokenExpired'}, 401);
          }
          expect(r.headers['Authorization'], 'Bearer $renewedAccess');
        }
        return _reply(r);
      });
      final api = _api(
        http,
        sessions,
        renew: (session) async {
          refreshes++;
          await sessions.update(session, {
            'accessToken': renewedAccess,
            'expiresAt': '${tokenClock + 3600000}',
          });
        },
      );
      await api.fresh(sessions.open(vault.credential(_platform)!));
      expect(authorizations, 2);
      expect(refreshes, 1);
    },
  );

  test(
    'an invalid ordinary login stops before sending a code to OpenList',
    () async {
      final vault = await tokenVault(_platform);
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final http = FakeHttp(
        (r) => r.uri.path == '/oauth/users/authorize'
            ? jsonResponse({'code': 'AccessTokenExpired'}, 401)
            : _reply(r),
      );
      final api = _api(
        http,
        sessions,
        renew: (_) async {
          throw const AccountLoginRequired('登录已失效');
        },
      );
      await expectLater(
        api.fresh(sessions.open(vault.credential(_platform)!)),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(
        http.calls.where((r) => r.uri.path == '/alicloud/callback'),
        isEmpty,
      );
      expect(vault.credential(_platform)!.field('openAccessToken'), isEmpty);
    },
  );

  test(
    'a second rejected OpenToken stops instead of repeatedly authorizing',
    () async {
      final vault = await tokenVault(
        _platform,
        tokenCredential(
          _platform,
          fields: {
            'openAccessToken': _openAccess,
            'openExpiresAt': '${tokenClock + 3600000}',
          },
        ),
      );
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final http = FakeHttp(
        (r) => r.uri.path == _previewPath
            ? jsonResponse({'code': 'AccessTokenExpired'}, 401)
            : _reply(r, access: _nextAccess),
      );
      await expectLater(
        _api(http, sessions).request(
          sessions.open(vault.credential(_platform)!),
          'openFile/getVideoPreviewPlayInfo',
          {},
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.where((r) => r.uri.path == _previewPath), hasLength(2));
      expect(
        http.calls.where((r) => r.uri.path == '/alicloud/callback'),
        hasLength(1),
      );
    },
  );

  for (final invalid in [
    ('access token', {..._tokens(), 'access_token': 'invalid token'}),
    ('refresh token', {..._tokens(), 'refresh_token': 'invalid token'}),
    ('token type', {..._tokens(), 'token_type': 'Basic'}),
    ('account', _tokens(user: 'another-user')),
    ('expiry', {..._tokens(), 'expires_in': 30}),
  ]) {
    test('an invalid OAuth ${invalid.$1} is not saved', () async {
      final vault = await tokenVault(_platform);
      final before = vault.credential(_platform)!;
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final http = FakeHttp(
        (r) => r.uri.path == '/alicloud/callback'
            ? _exchange(invalid.$2)
            : _reply(r),
      );
      await expectLater(
        _api(http, sessions).fresh(sessions.open(before)),
        throwsA(isA<AppException>()),
      );
      expect(vault.credential(_platform)!.sameAs(before), isTrue);
    });
  }

  test(
    'URL-escaped base64url tokens in a redirect fragment are decoded',
    () async {
      final vault = await tokenVault(_platform);
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final http = FakeHttp(
        (r) => r.uri.path == '/alicloud/callback'
            ? _exchange(_tokens(), escaped: true)
            : _reply(r),
      );
      await _api(
        http,
        sessions,
      ).fresh(sessions.open(vault.credential(_platform)!));
      expect(
        vault.credential(_platform)!.field('openAccessToken'),
        _openAccess,
      );
    },
  );

  for (final failure in [
    const HttpResult(200, '{}'),
    const HttpResult(502, 'upstream unavailable'),
    const HttpResult(302, '', {
      'location': ['https://example.com/#invalid'],
    }),
  ]) {
    test(
      'a malformed callback response (${failure.status}, ${failure.body}) fails without following redirects',
      () async {
        final vault = await tokenVault(_platform);
        final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
        final http = _RedirectHttp(
          (r) => r.uri.path == '/alicloud/callback' ? failure : _reply(r),
        );
        await expectLater(
          _api(
            http,
            sessions,
          ).fresh(sessions.open(vault.credential(_platform)!)),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(3));
        expect(http.redirects, everyElement(isFalse));
        expect(vault.credential(_platform)!.field('openAccessToken'), isEmpty);
      },
    );
  }

  test(
    'an unexpected callback origin or mismatched OAuth state is rejected',
    () async {
      for (final returned in [
        'https://example.com/callback?code=fixture-code&state=fixture-state',
        '$_oauthCallback?code=fixture-code&state=different-state',
      ]) {
        final vault = await tokenVault(_platform);
        final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
        final http = FakeHttp(
          (r) => r.uri.path == '/oauth/users/authorize'
              ? jsonResponse({'redirectUri': returned})
              : _reply(r, state: 'fixture-state'),
        );
        await expectLater(
          _api(
            http,
            sessions,
          ).fresh(sessions.open(vault.credential(_platform)!)),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(2));
      }
    },
  );

  test(
    'invalid bootstrap endpoints never receive the ordinary access token',
    () async {
      for (final bootstrap in [
        jsonResponse({
          'text':
              'https://example.com/oauth/authorize?client_id=fixture-client',
        }),
        _bootstrap(redirect: 'https://example.com/callback'),
        const HttpResult(200, '{}'),
      ]) {
        final vault = await tokenVault(_platform);
        final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
        final http = FakeHttp((_) => bootstrap);
        await expectLater(
          _api(
            http,
            sessions,
          ).fresh(sessions.open(vault.credential(_platform)!)),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(1));
        expect(http.calls.single.headers['Authorization'], isNull);
      }
    },
  );

  for (final boundary in [
    '/alicloud/requests',
    '/oauth/users/authorize',
    '/alicloud/callback',
  ]) {
    for (final replace in [false, true]) {
      test(
        '${replace ? 'account replacement' : 'cancellation'} rejects a delayed $boundary result',
        () async {
          final vault = await tokenVault(_platform);
          final sessions = TokenSessions(
            _platform,
            vault,
            now: () => tokenClock,
          );
          final entered = Completer<void>(), release = Completer<void>();
          final http = FakeHttp((r) async {
            if (r.uri.path == boundary) {
              entered.complete();
              await release.future;
            }
            return _reply(r);
          });
          final scope = RequestScope();
          final pending = scope.run(
            () => _api(http, sessions).request(
              sessions.open(vault.credential(_platform)!),
              'openFile/getVideoPreviewPlayInfo',
              {},
            ),
          );
          final rejected = expectLater(pending, throwsA(isA<AppException>()));
          await entered.future;
          if (replace) {
            await vault.putCredential(
              _platform,
              tokenCredential(_platform, revision: 99),
            );
          } else {
            scope.cancel();
          }
          release.complete();
          await rejected;
          await Future<void>.delayed(Duration.zero);
          expect(
            vault.credential(_platform)!.field('openAccessToken'),
            isEmpty,
          );
          expect(http.calls.where((r) => r.uri.path == _previewPath), isEmpty);
          if (replace) expect(vault.credential(_platform)!.updatedAt, 99);
        },
      );
    }
  }

  test(
    'OpenTokens stay attached to the original account after activation changes',
    () async {
      final vault = await tokenVault(_platform);
      final original = vault.activeAccountId(_platform)!;
      final other = await vault.createAccount(_platform);
      await vault.withAccount(
        _platform,
        other,
        () => vault.putCredential(
          _platform,
          tokenCredential(
            _platform,
            revision: 99,
            fields: {'userId': 'user-2'},
          ),
        ),
      );
      await vault.activate(_platform, other);
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final http = FakeHttp((r) => _reply(r));
      final api = _api(http, sessions);
      await vault.withAccount(
        _platform,
        original,
        () => api.fresh(sessions.open(vault.credential(_platform)!)),
      );
      expect(
        vault.credentialFor(_platform, original)!.field('openAccessToken'),
        _openAccess,
      );
      expect(
        vault.credentialFor(_platform, other)!.field('openAccessToken'),
        isEmpty,
      );
      expect(vault.activeAccountId(_platform), other);
    },
  );

  test(
    'a callback code is single-use and is excluded from generic read retries',
    () async {
      final vault = await tokenVault(_platform);
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final upstream = FakeHttp((r) {
        if (r.uri.path == '/alicloud/callback') {
          throw const HttpRequestFailure(
            'network error',
            kind: 'connectionError',
            retryable: true,
          );
        }
        return _reply(r);
      });
      final api = _api(RetryingJsonHttp(upstream), sessions);
      final retries = ReadRetryScope(
        retries: 3,
        checkpoint: RequestScope.checkpoint,
        wait: (_) async {},
      );
      await expectLater(
        retries.run(
          () => api.fresh(sessions.open(vault.credential(_platform)!)),
        ),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(
        upstream.calls.where((r) => r.uri.path == '/alicloud/callback'),
        hasLength(1),
      );
    },
  );

  test(
    'direct read throttling has three retries and mutations are not replayed',
    () async {
      final vault = await tokenVault(
        _platform,
        tokenCredential(
          _platform,
          fields: {
            'openAccessToken': _openAccess,
            'openExpiresAt': '${tokenClock + 3600000}',
          },
        ),
      );
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      var calls = 0;
      final waits = <Duration>[];
      final http = FakeHttp((_) {
        calls++;
        return calls < 4
            ? jsonResponse({'code': 'TooManyRequests'}, 429)
            : jsonResponse({});
      });
      final api = _api(
        http,
        sessions,
        wait: (duration) async => waits.add(duration),
      );
      await api.request(
        sessions.open(vault.credential(_platform)!),
        'openFile/getDownloadUrl',
        {},
      );
      expect(calls, 4);
      expect(waits, List.filled(3, const Duration(seconds: 1)));
      final mutationHttp = FakeHttp(
        (_) => jsonResponse({'code': 'TooManyRequests'}, 429),
      );
      await expectLater(
        _api(mutationHttp, sessions).request(
          sessions.open(vault.credential(_platform)!),
          'openFile/create',
          {},
          read: false,
        ),
        throwsA(isA<AliyunPlaybackApiException>()),
      );
      expect(mutationHttp.calls, hasLength(1));
    },
  );

  test(
    'business errors do not copy credentials from server text into exceptions',
    () async {
      final vault = await tokenVault(
        _platform,
        tokenCredential(
          _platform,
          fields: {
            'openAccessToken': _openAccess,
            'openExpiresAt': '${tokenClock + 3600000}',
          },
        ),
      );
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      final http = FakeHttp(
        (_) => jsonResponse({
          'code': 'InvalidParameter',
          'message': 'private $_openAccess $_openRefresh',
        }, 400),
      );
      await expectLater(
        _api(http, sessions).request(
          sessions.open(vault.credential(_platform)!),
          'openFile/getDownloadUrl',
          {},
        ),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'safe message',
            allOf(isNot(contains(_openAccess)), isNot(contains(_openRefresh))),
          ),
        ),
      );
    },
  );

  test(
    'a non-JSON throttle response still retries the open API read',
    () async {
      final vault = await tokenVault(
        _platform,
        tokenCredential(
          _platform,
          fields: {
            'openAccessToken': _openAccess,
            'openExpiresAt': '${tokenClock + 3600000}',
          },
        ),
      );
      final sessions = TokenSessions(_platform, vault, now: () => tokenClock);
      var calls = 0;
      final http = FakeHttp((_) {
        calls++;
        return calls == 1
            ? const HttpResult(429, 'too many requests')
            : jsonResponse({});
      });
      await _api(http, sessions).request(
        sessions.open(vault.credential(_platform)!),
        'openFile/getVideoPreviewPlayInfo',
        {},
      );
      expect(calls, 2);
    },
  );
}
