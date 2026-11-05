import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

String _signature(Map<String, Object?> values) {
  final pairs = values.entries.map((e) => '${e.key}=${e.value}').toList()
    ..sort();
  return md5.convert(utf8.encode(pairs.join('&'))).toString();
}

class _TianyiFamilyFixture {
  _TianyiFamilyFixture() {
    http = FakeHttp(
      (request) async => await override?.call(request) ?? respond(request),
    );
    connector = TianyiConnector(http);
  }

  late final FakeHttp http;
  late final TianyiConnector connector;
  final credential = Credential('天翼测试账号', {
    'primary': 'COOKIE_LOGIN_USER=family-cookie',
  }, updatedAt: 1);
  int exchanges = 0;
  String expectedCookie = 'family-cookie';
  FutureOr<HttpResult?> Function(RecordedRequest)? override;

  int count(String operation) =>
      http.calls.where((r) => r.uri.path.endsWith('/$operation.action')).length;

  HttpResult respond(RecordedRequest request) {
    final path = request.uri.path;
    final params = request.uri.queryParameters;
    final headers = request.headers;
    if (path.startsWith('/api/open/family/')) {
      // This is the failure observed in the 0.3.33 device log.
      return jsonResponse({'errorCode': 'AppNotExist'}, 400);
    }
    if (path == '/api/portal/v2/getUserBriefInfo.action') {
      expect(headers['Cookie'], contains('COOKIE_LOGIN_USER=$expectedCookie'));
      return jsonResponse({'res_code': 0, 'sessionKey': 'family-session'});
    }
    if (path == '/api/open/oauth2/getAccessTokenBySsKey.action') {
      expect(request.uri.host, 'cloud.189.cn');
      expect(params['sessionKey'], 'family-session');
      expect(headers['AppKey'], '600100422');
      expect(headers['Timestamp'], matches(r'^\d{13}$'));
      expect(
        headers['Signature'],
        _signature({
          'AppKey': '600100422',
          'Timestamp': headers['Timestamp'],
          'sessionKey': 'family-session',
        }),
      );
      exchanges++;
      return jsonResponse({'accessToken': 'family-access-$exchanges'});
    }
    expect(request.uri.host, 'api.cloud.189.cn');
    expect(path, startsWith('/open/family/'));
    expect(headers.containsKey('Cookie'), isFalse);
    expect(headers['AccessToken'], 'family-access-$exchanges');
    expect(headers['Sign-Type'], '1');
    expect(params.containsKey('noCache'), isFalse);
    expect(
      headers['Signature'],
      _signature({
        ...params,
        'AccessToken': headers['AccessToken'],
        'Timestamp': headers['Timestamp'],
      }),
    );
    if (path.endsWith('/getFamilyList.action')) {
      return jsonResponse({
        'familyInfoResp': [
          {'familyId': 12001, 'remarkName': '我们的家庭'},
        ],
      });
    }
    expect(params['familyId'], '12001');
    if (path.endsWith('/listFiles.action')) {
      expect(params['folderId'], '');
      return jsonResponse({
        'fileListAO': {
          'count': 1,
          'folderList': [],
          'fileList': [
            {'id': 'video-1', 'name': '假期.mp4', 'size': 1000},
          ],
        },
      });
    }
    expect(path, '/open/family/file/getFileDownloadUrl.action');
    expect(params['type'], '1');
    expect(params.containsKey('dt'), isFalse);
    return jsonResponse({
      'fileDownloadUrl': 'https://files.example.test/family-video.mp4',
    });
  }
}

class _MobileFamilyFixture {
  _MobileFamilyFixture() {
    http = FakeHttp(respond);
    connector = C139Connector(http);
  }

  late final FakeHttp http;
  late final C139Connector connector;
  final credential = Credential('移动测试账号', {
    'primary': 'skey=family-skey; ud_id=family-domain',
    'authorization':
        'Basic ${base64Encode(utf8.encode('pc:13800000000:test-token'))}',
  }, updatedAt: 1);

  HttpResult respond(RecordedRequest request) {
    final body = request.json;
    final downloading = request.uri.path.endsWith('/getFileDownLoadURL');
    final identityKey = downloading ? 'account' : 'userDomainId';
    if (body.obj('commonAccountInfo').str(identityKey).isEmpty) {
      // The real log retained this message, but not the server's code.
      return jsonResponse({
        'success': false,
        'code': '9999',
        'message': '家庭云未知异常',
      });
    }
    expect(request.uri.host, 'yun.139.com');
    expect(body['commonAccountInfo'], {
      identityKey: downloading ? '13800000000' : 'family-domain',
      'accountType': 1,
    });
    expect(request.headers['mcloud-userid-flag'], downloading ? isNull : '1');
    expect(request.headers['mcloud-skey'], 'family-skey');
    expect(request.headers['x-SvcType'], '2');
    expect(request.headers['x-yun-svc-type'], '2');
    final sign = request.headers['mcloud-sign']!.split(',');
    expect(
      sign[2],
      C139Protocol.calculateSign(request.body! as String, sign[0], sign[1]),
    );
    if (request.uri.path.endsWith('/queryFamilyCloud')) {
      return jsonResponse({
        'success': true,
        'code': '0',
        'data': {
          'totalCount': 1,
          'familyCloudList': [
            {'cloudID': 'family-1', 'cloudName': '我们的家庭'},
          ],
        },
      });
    }
    expect(body['cloudID'], 'family-1');
    if (request.uri.path.endsWith('/queryContentList')) {
      return jsonResponse({
        'success': true,
        'code': '0',
        'data': {
          'result': {'resultCode': '0'},
          'path': 'root:/family-root',
          'totalCount': 1,
          'cloudCatalogList': [],
          'cloudContentList': [
            {
              'contentID': 'video-1',
              'contentName': '假期.mp4',
              'contentSize': 1000,
            },
          ],
        },
      });
    }
    expect(request.uri.path, endsWith('/getFileDownLoadURL'));
    expect(body['path'], 'root:/family-root');
    return jsonResponse({
      'success': true,
      'code': '0',
      'data': {'downloadURL': 'https://files.example.test/family-video.mp4'},
    });
  }
}

void main() {
  test(
    'Tianyi family links restore HTML separators without changing signed bytes',
    () async {
      final f = _TianyiFamilyFixture();
      const raw =
          'http://download.cloud.189.cn/file?sign=a%2bb&amp;name=%e4%b8%ad&amp;key=1&amp;key=2&amp;literal=%26amp%3B';
      f.override = (r) => r.uri.path.endsWith('/getFileDownloadUrl.action')
          ? jsonResponse({'fileDownloadUrl': raw})
          : null;
      final spaces = await f.connector.familySpaces(f.credential);
      final session = await f.connector.openFamily(spaces.single, f.credential);
      const file = CloudFile(id: 'video-1', name: 'fixture.mp4', size: 1000);
      for (final prepare in [f.connector.download, f.connector.playback]) {
        final spec = await prepare(session, file, f.credential);
        expect(
          spec.url,
          'https://download.cloud.189.cn/file?sign=a%2bb&name=%e4%b8%ad&key=1&key=2&literal=%26amp%3B',
        );
        expect(
          spec.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('cookie')),
        );
        expect(spec.expectedSize, 1000);
      }
    },
  );

  test(
    'Tianyi preserves other CDNs, explicit ports and existing percent escapes',
    () async {
      for (final expected in [
        'http://files.example.test/video?sign=a%2bb&literal=%26amp%3B',
        'http://download.cloud.189.cn:80/video?sign=a%2bb&literal=%26amp%3B',
        'http://download.cloud.189.cn:8080/video?sign=a%2bb',
        'https://download.cloud.189.cn:443/video?sign=a%2bb',
      ]) {
        final f = _TianyiFamilyFixture();
        f.override = (r) => r.uri.path.endsWith('/getFileDownloadUrl.action')
            ? jsonResponse({'fileDownloadUrl': expected})
            : null;
        final spaces = await f.connector.familySpaces(f.credential);
        final session = await f.connector.openFamily(
          spaces.single,
          f.credential,
        );
        final spec = await f.connector.download(
          session,
          const CloudFile(id: 'video-1', name: 'fixture.mp4'),
          f.credential,
        );
        expect(spec.url, expected);
      }
    },
  );

  test(
    'Tianyi family browsing exchanges the web session and signs every family request',
    () async {
      final f = _TianyiFamilyFixture();
      final spaces = await f.connector.familySpaces(f.credential);
      expect(spaces.single.id, '12001');
      final session = await f.connector.openFamily(spaces.single, f.credential);
      final files = await f.connector.list(
        session,
        session.rootId,
        f.credential,
      );
      final download = await f.connector.download(
        session,
        files.single,
        f.credential,
      );
      expect(download.url, 'https://files.example.test/family-video.mp4');
      expect(f.exchanges, 1);
      expect(download.headers.containsKey('Cookie'), isFalse);
      expect(download.headers.containsKey('AccessToken'), isFalse);
    },
  );

  test(
    'Mobile family discovery, directory and downloads carry the matching account identity',
    () async {
      final f = _MobileFamilyFixture();
      final spaces = await f.connector.familySpaces(f.credential);
      expect(spaces.single.id, 'family-1');
      final session = await f.connector.openFamily(spaces.single, f.credential);
      final files = await f.connector.list(
        session,
        session.rootId,
        f.credential,
      );
      final download = await f.connector.download(
        session,
        files.single,
        f.credential,
      );
      expect(download.url, 'https://files.example.test/family-video.mp4');
      expect(f.http.calls, hasLength(4));
    },
  );

  test(
    'Tianyi refreshes an expired family token using the existing web login',
    () async {
      final f = _TianyiFamilyFixture();
      await f.connector.familySpaces(f.credential);
      f.override = (request) =>
          request.headers['AccessToken'] == 'family-access-1'
          ? jsonResponse({'errorCode': 'AccessTokenHasExpired'}, 400)
          : null;
      expect(await f.connector.familySpaces(f.credential), hasLength(1));
      expect(f.exchanges, 2);
      expect(f.count('getUserBriefInfo'), 2);
      expect(f.count('getFamilyList'), 3);
    },
  );

  test('Tianyi stops after one rejected family-token refresh', () async {
    final f = _TianyiFamilyFixture();
    f.override = (request) => request.uri.path.startsWith('/open/family/')
        ? jsonResponse({'errorCode': 'InvalidAccessToken'}, 400)
        : null;
    await expectLater(
      f.connector.familySpaces(f.credential),
      throwsA(isA<AccountLoginRequired>()),
    );
    expect(f.exchanges, 2);
    expect(f.count('getFamilyList'), 2);
  });

  test(
    'Tianyi rereads the session key when a token exchange rejects it',
    () async {
      final f = _TianyiFamilyFixture();
      var briefs = 0;
      f.override = (request) {
        if (request.uri.path.endsWith('/getUserBriefInfo.action') &&
            ++briefs == 1) {
          return jsonResponse({'sessionKey': 'expired-session'});
        }
        if (request.uri.queryParameters['sessionKey'] == 'expired-session') {
          return jsonResponse({'errorCode': 'InvalidSessionKey'}, 400);
        }
        return null;
      };
      expect(await f.connector.familySpaces(f.credential), hasLength(1));
      expect(f.count('getUserBriefInfo'), 2);
      expect(f.count('getAccessTokenBySsKey'), 2);
      expect(f.exchanges, 1);
    },
  );

  for (final stage in ['getUserBriefInfo', 'getAccessTokenBySsKey']) {
    test(
      'Cancellation during Tianyi $stage prevents using the late response',
      () async {
        final f = _TianyiFamilyFixture();
        final entered = Completer<void>(), release = Completer<void>();
        f.override = (request) async {
          if (request.uri.path.endsWith('/$stage.action')) {
            entered.complete();
            await release.future;
          }
          return null;
        };
        final scope = RequestScope();
        final pending = scope.run(() => f.connector.familySpaces(f.credential));
        final rejected = expectLater(
          pending,
          throwsA(
            isA<AppException>().having(
              (error) => error.message,
              'message',
              contains('取消'),
            ),
          ),
        );
        await entered.future;
        scope.cancel();
        release.complete();
        await rejected;
        expect(f.count('getFamilyList'), 0);
        final previousExchanges = f.exchanges;
        f.override = null;
        expect(await f.connector.familySpaces(f.credential), hasLength(1));
        expect(f.exchanges, previousExchanges + 1);
      },
    );
  }

  test(
    'Changing accounts during Tianyi authorization discards the late token',
    () async {
      final f = _TianyiFamilyFixture();
      final state = StateStore.memory({
        'credentials': {'Tianyi': f.credential.toJson()},
      });
      addTearDown(state.dispose);
      final vault = Vault(state),
          connector = TianyiConnector(f.http, store: Vault(state));
      final entered = Completer<void>(), release = Completer<void>();
      f.override = (request) async {
        if (request.uri.path.endsWith('/getAccessTokenBySsKey.action')) {
          entered.complete();
          await release.future;
        }
        return null;
      };
      final pending = connector.familySpaces(f.credential);
      final rejected = expectLater(
        pending,
        throwsA(isA<AccountLoginRequired>()),
      );
      await entered.future;
      final replacement = Credential(
        '另一个登录',
        f.credential.fields,
        updatedAt: 2,
      );
      await vault.putCredential(CloudPlatform.tianyi, replacement);
      release.complete();
      await rejected;
      expect(f.count('getFamilyList'), 0);
      f.override = null;
      expect(await connector.familySpaces(replacement), hasLength(1));
      expect(f.exchanges, 2);
      expect(encoded(state.data), isNot(contains('family-access-')));
      expect(encoded(state.data), isNot(contains('family-session')));
    },
  );

  test(
    'Tianyi cached family tokens are invalidated by a new login revision',
    () async {
      final f = _TianyiFamilyFixture();
      final state = StateStore.memory({
        'credentials': {'Tianyi': f.credential.toJson()},
      });
      addTearDown(state.dispose);
      final vault = Vault(state),
          connector = TianyiConnector(f.http, store: Vault(state));
      await connector.familySpaces(f.credential);
      final replacement = Credential(
        f.credential.label,
        f.credential.fields,
        updatedAt: 2,
      );
      await vault.putCredential(CloudPlatform.tianyi, replacement);
      expect(await connector.familySpaces(replacement), hasLength(1));
      expect(f.exchanges, 2);
    },
  );

  test(
    'Tianyi family bootstrap can renew an expired saved password login',
    () async {
      final f = _TianyiFamilyFixture();
      final initial = f.credential.withFields({
        'authType': 'passwordCookie',
        'username': 'fixture-user',
        'password': 'fixture-password',
        'userId': 'fixture-id',
        'loginName': 'fixture-user',
      }, preserveRevision: true);
      final state = StateStore.memory({
        'credentials': {'Tianyi': initial.toJson()},
      });
      addTearDown(state.dispose);
      final vault = Vault(state);
      var renewals = 0;
      final connector = TianyiConnector(
        f.http,
        store: vault,
        passwordLogin: (username, password) async {
          expect(username, 'fixture-user');
          expect(password, 'fixture-password');
          renewals++;
          f.expectedCookie = 'renewed-family-cookie';
          return LoginResult(
            initial.withFields({
              'primary': 'COOKIE_LOGIN_USER=renewed-family-cookie',
            }),
            const CloudAccount('天翼测试账号'),
          );
        },
      );
      f.override = (request) =>
          request.uri.path.endsWith('/getUserBriefInfo.action') &&
              request.headers['Cookie'] == initial.primary
          ? jsonResponse({'errorCode': 'InvalidSessionKey'}, 400)
          : null;
      expect(await connector.familySpaces(initial), hasLength(1));
      expect(renewals, 1);
      expect(f.exchanges, 1);
      expect(
        vault.credential(CloudPlatform.tianyi)!.primary,
        contains('renewed-family-cookie'),
      );
      expect(
        vault.credential(CloudPlatform.tianyi)!.field('autoLoginBlocked'),
        isEmpty,
      );
    },
  );

  test(
    'Tianyi personal downloads retain cookie authentication without share parameters',
    () async {
      final f = _TianyiFamilyFixture();
      await f.connector.familySpaces(f.credential);
      f.override = (request) {
        if (request.uri.path == '/api/open/file/getFileDownloadUrl.action') {
          expect(request.headers['Cookie'], f.credential.primary);
          expect(request.headers.containsKey('AccessToken'), isFalse);
          expect(request.uri.queryParameters.containsKey('dt'), isFalse);
          expect(request.uri.queryParameters.containsKey('shareId'), isFalse);
          expect(request.uri.queryParameters.containsKey('familyId'), isFalse);
          return jsonResponse({
            'fileDownloadUrl': 'https://files.example.test/personal.mp4',
          });
        }
        return null;
      };
      final session = await f.connector.openPersonal(f.credential);
      final spec = await f.connector.download(
        session,
        const CloudFile(id: 'personal-video', name: '个人.mp4'),
        f.credential,
      );
      expect(spec.url, 'https://files.example.test/personal.mp4');
      expect(f.exchanges, 1);
    },
  );

  test(
    'A late Tianyi expiry response reuses the token already refreshed by another request',
    () async {
      final f = _TianyiFamilyFixture();
      await f.connector.familySpaces(f.credential);
      final entered = Completer<void>(), release = Completer<void>();
      var rejectedRequests = 0;
      f.override = (request) async {
        if (request.headers['AccessToken'] == 'family-access-1') {
          rejectedRequests++;
          if (rejectedRequests == 1) {
            entered.complete();
            await release.future;
          }
          return jsonResponse({'errorCode': 'InvalidAccessToken'}, 400);
        }
        return null;
      };
      final earlier = f.connector.familySpaces(f.credential);
      await entered.future;
      expect(await f.connector.familySpaces(f.credential), hasLength(1));
      release.complete();
      expect(await earlier, hasLength(1));
      expect(f.exchanges, 2);
    },
  );

  for (final field in ['sessionKey', 'accessToken']) {
    test(
      'Tianyi rejects malformed $field without sending it to the family API',
      () async {
        for (final value in <Object?>[null, '', 12345, {}, 'bad\nvalue']) {
          final f = _TianyiFamilyFixture();
          final operation = field == 'sessionKey'
              ? 'getUserBriefInfo'
              : 'getAccessTokenBySsKey';
          f.override = (request) =>
              request.uri.path.endsWith('/$operation.action')
              ? jsonResponse({field: value})
              : null;
          await expectLater(
            f.connector.familySpaces(f.credential),
            throwsA(isA<AppException>()),
          );
          expect(f.count('getFamilyList'), 0);
        }
      },
    );
  }

  test(
    'Legacy Mobile authorizations send account identity without a user-domain flag',
    () async {
      final credential = Credential('旧移动登录', {
        'authorization':
            'Basic ${base64Encode(utf8.encode('pc:13800000000:legacy-token'))}',
      });
      final http = FakeHttp((request) {
        expect(request.json['commonAccountInfo'], {
          'account': '13800000000',
          'accountType': 1,
        });
        expect(request.headers.containsKey('mcloud-userid-flag'), isFalse);
        expect(request.headers.containsKey('Cookie'), isFalse);
        expect(request.headers.containsKey('mcloud-skey'), isFalse);
        return jsonResponse({
          'success': true,
          'code': '0',
          'data': {'totalCount': 0, 'familyCloudList': []},
        });
      });
      expect(await C139Connector(http).familySpaces(credential), isEmpty);
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'Mobile family identity uses the decoded current cookie before a saved domain',
    () async {
      final credential = _MobileFamilyFixture().credential.withFields({
        'primary': 'skey=family-skey; ud_id=current%2Bdomain%2Fvalue',
        'userDomainId': 'stale-domain',
      });
      final http = FakeHttp((request) {
        expect(request.json['commonAccountInfo'], {
          'userDomainId': 'current+domain/value',
          'accountType': 1,
        });
        expect(request.headers['mcloud-userid-flag'], '1');
        return jsonResponse({
          'success': true,
          'code': '0',
          'data': {'totalCount': 0, 'familyCloudList': []},
        });
      });
      expect(await C139Connector(http).familySpaces(credential), isEmpty);
    },
  );

  test(
    'Mobile stops incomplete authorization before submitting an unidentified family request',
    () async {
      final http = FakeHttp();
      await expectLater(
        C139Connector(
          http,
        ).familySpaces(Credential('不完整登录', {'authorization': 'Basic invalid'})),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, isEmpty);
    },
  );

  for (final nested in [false, true]) {
    test(
      'Mobile logs the ${nested ? 'nested' : 'outer'} family error code without response payload or credentials',
      () async {
        final log = DiagnosticLog.open(null);
        DiagnosticLog.active = log;
        addTearDown(() {
          DiagnosticLog.active = null;
          log.close();
        });
        final http = FakeHttp(
          (_) => jsonResponse(
            nested
                ? {
                    'success': true,
                    'code': '0',
                    'data': {
                      'result': {
                        'resultCode': 'FAMILY_DENIED',
                        'desc': '家庭云未知异常',
                      },
                      'privateResponse': 'RESPONSE_SECRET_SENTINEL',
                    },
                  }
                : {
                    'success': false,
                    'code': 'FAMILY_DENIED',
                    'message': '家庭云未知异常',
                    'privateResponse': 'RESPONSE_SECRET_SENTINEL',
                  },
          ),
        );
        await expectLater(
          C139Connector(http).familySpaces(_MobileFamilyFixture().credential),
          throwsA(isA<AppException>()),
        );
        final entry = log.entries().singleWhere(
          (e) => e.event == 'cloud.family.request_failed',
        );
        expect(entry.data.obj('fields'), {
          'platform': 'C139',
          'stage': 'queryFamilyCloud',
          'httpStatus': 200,
          'serverCode': 'FAMILY_DENIED',
        });
        final text = log.exportFiles().values.join();
        for (final value in [
          'family-skey',
          'family-domain',
          'test-token',
          'RESPONSE_SECRET_SENTINEL',
          '13800000000',
        ]) {
          expect(text, isNot(contains(value)));
        }
      },
    );
  }

  test(
    'Tianyi records the authorization failure stage without session keys or response secrets',
    () async {
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = null;
        log.close();
      });
      final f = _TianyiFamilyFixture();
      f.override = (request) =>
          request.uri.path.endsWith('/getAccessTokenBySsKey.action')
          ? jsonResponse({
              'errorCode': 'AppNotExist',
              'privateResponse': 'RESPONSE_SECRET_SENTINEL',
            }, 400)
          : null;
      await expectLater(
        f.connector.familySpaces(f.credential),
        throwsA(isA<AppException>()),
      );
      final entry = log.entries().singleWhere(
        (e) => e.event == 'cloud.family.request_failed',
      );
      expect(entry.data.obj('fields'), {
        'platform': 'Tianyi',
        'stage': 'authorize',
        'httpStatus': 400,
        'serverCode': 'AppNotExist',
      });
      final text = log.exportFiles().values.join();
      for (final value in [
        'family-session',
        'family-cookie',
        'family-access-',
        'RESPONSE_SECRET_SENTINEL',
      ]) {
        expect(text, isNot(contains(value)));
      }
    },
  );

  test('Disabled diagnostics do not record family request failures', () async {
    final log = DiagnosticLog.open(null, enabled: false);
    DiagnosticLog.active = log;
    addTearDown(() {
      DiagnosticLog.active = null;
      log.close();
    });
    final http = FakeHttp(
      (_) => jsonResponse({
        'success': false,
        'code': 'FAMILY_DENIED',
        'message': '家庭云未知异常',
      }),
    );
    await expectLater(
      C139Connector(http).familySpaces(_MobileFamilyFixture().credential),
      throwsA(isA<AppException>()),
    );
    expect(log.entries(), isEmpty);
  });
}
