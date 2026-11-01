import 'dart:convert';
import 'dart:typed_data';

import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu_link_service.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'support.dart';

void main() {
  late AsymmetricKeyPair<PublicKey, PrivateKey> keys;
  late String publicKey;
  setUpAll(() {
    final random = FortunaRandom()..seed(KeyParameter(CryptoBox.random(32)));
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 3072, 64),
          random,
        ),
      );
    keys = generator.generateKeyPair();
    publicKey = (keys.publicKey as RSAPublicKey).modulus!.toRadixString(16);
  });

  Uint8List decryptKey(RecordedRequest call) {
    final cipher = OAEPEncoding.withSHA256(RSAEngine())
      ..init(
        false,
        PrivateKeyParameter<RSAPrivateKey>(keys.privateKey as RSAPrivateKey),
      );
    return cipher.process(base64Decode(call.json.str('key')));
  }

  HttpResult reply(RecordedRequest call, Json body, {String? aad}) {
    final nonce = CryptoBox.random(12);
    final encrypted = crypt(
      true,
      decryptKey(call),
      nonce,
      Uint8List.fromList(utf8.encode(jsonEncode(body))),
      aad ?? 'wenxi-link-v1/response/${call.json.str('nonce')}',
    );
    return jsonResponse({
      'version': 1,
      'nonce': base64Encode(nonce),
      'data': base64Encode(encrypted),
    });
  }

  BaiduLinkService service(JsonHttp http) => BaiduLinkService(
    http,
    endpoint: 'http://fixture.invalid:8766/',
    publicKey: publicKey,
    accessKey: 'fixture-access',
  );
  Future<BaiduResolvedLink> resolve(
    BaiduLinkService client, [
    String cookie = 'BDUSS=fixture',
  ]) => client.resolve(
    cookie: cookie,
    path: '/private-file.zip',
    fileId: '42',
    appId: '250528',
    device: {'id': 'fixture-device', 'downloadVersion': '13.15.4'},
  );
  const good = {
    'ok': true,
    'url': 'https://fixture.baidupcs.com/file',
    'profile': 'baidu_preview',
    'downloadVersion': '13.15.4',
  };

  test(
    'Each concurrent request carries only its own encrypted account',
    () async {
      final accounts = <String>[];
      final http = _Transport((call) {
        expect(call.method, 'POST');
        expect(call.url, 'http://fixture.invalid:8766/v1/resolve');
        final wire = '${call.body} ${call.headers}';
        for (final secret in ['BDUSS=', 'fixture-access', 'private-file.zip']) {
          expect(wire, isNot(contains(secret)));
        }
        final input = asJson(
          jsonDecode(
            utf8.decode(
              crypt(
                false,
                decryptKey(call),
                base64Decode(call.json.str('nonce')),
                base64Decode(call.json.str('data')),
                'wenxi-link-v1/request',
              ),
            ),
          ),
        );
        accounts.add(input.str('cookie'));
        expect(input.str('path'), '/private-file.zip');
        expect(input.str('fileId'), '42');
        expect(input.str('accessKey'), 'fixture-access');
        expect(input['device']['downloadVersion'], '13.15.4');
        expect(input['device']['directDelivery'], 1);
        return reply(call, good);
      });
      final client = service(http);
      final result = await Future.wait([
        resolve(client, 'BDUSS=alice'),
        resolve(client, 'BDUSS=bob'),
      ]);
      expect(accounts, unorderedEquals(['BDUSS=alice', 'BDUSS=bob']));
      expect(result.every((link) => link.preview), isTrue);
      expect(http.redirects, everyElement(isFalse));
      expect(http.calls.map((c) => c.json.str('nonce')).toSet(), hasLength(2));
      expect(http.calls.map((c) => c.json.str('key')).toSet(), hasLength(2));
    },
  );

  test(
    'Direct delivery receives dynamic headers and rejects credential injection',
    () async {
      const direct = {
        'ok': true,
        'url': 'https://fixture.baidupcs.com/file',
        'profile': 'baidu_direct',
        'downloadVersion': '13.15.4',
        'headers': {
          'Host': 'fixture_route.baidu-int.com',
          'User-Agent': 'netdisk',
          'Accept-Encoding': 'identity',
        },
      };
      final link = await resolve(
        service(FakeHttp((call) => reply(call, direct))),
      );
      expect(link.profile, 'baidu_direct');
      expect(link.preview, isFalse);
      expect(link.headers['host'], 'fixture_route.baidu-int.com');
      expect(link.headers.containsKey('cookie'), isFalse);
      for (final headers in [
        {...(direct['headers'] as Map), 'Cookie': 'BDUSS=private'},
        {...(direct['headers'] as Map), 'Host': 'evil.invalid'},
        {
          ...(direct['headers'] as Map),
          'Host': 'fixture.baidu-int.com\r\nCookie:private',
        },
        {...(direct['headers'] as Map), 'User-Agent': 'unexpected'},
      ]) {
        await expectLater(
          resolve(
            service(
              FakeHttp((call) => reply(call, {...direct, 'headers': headers})),
            ),
          ),
          throwsA(isA<AppException>()),
        );
      }
    },
  );

  test(
    'An older service cannot return a link bound to a different download UA',
    () async {
      for (final version in [null, '12.1.3']) {
        final response = {...good}..remove('downloadVersion');
        if (version != null) response['downloadVersion'] = version;
        final http = FakeHttp((call) => reply(call, response));
        await expectLater(
          resolve(service(http)),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('更新服务'),
            ),
          ),
        );
      }
    },
  );

  test(
    'Tampered ciphertext and a response for another request are rejected',
    () async {
      for (final mode in ['tamper', 'wrong-request', 'malformed']) {
        final http = FakeHttp((call) {
          if (mode == 'malformed') {
            return const HttpResult(200, '<html>error</html>');
          }
          final response = reply(
            call,
            good,
            aad: mode == 'wrong-request' ? 'wenxi-link-v1/response/old' : null,
          );
          if (mode != 'tamper') return response;
          final data = response.json;
          final bytes = base64Decode(data.str('data'));
          bytes[0] ^= 1;
          return jsonResponse({...data, 'data': base64Encode(bytes)});
        });
        await expectLater(
          resolve(service(http)),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('响应校验失败'),
            ),
          ),
        );
      }
    },
  );

  test(
    'Encrypted account expiry asks to log in, service failures do not',
    () async {
      final expired = FakeHttp(
        (call) => reply(call, {
          'ok': false,
          'code': 'login_required',
          'message': 'untrusted detail',
        }),
      );
      await expectLater(
        resolve(service(expired)),
        throwsA(isA<AccountLoginRequired>()),
      );
      for (final code in [
        'unauthorized',
        'clock',
        'invalid_request',
        'upstream',
      ]) {
        final http = FakeHttp(
          (call) => reply(call, {
            'ok': false,
            'code': code,
            'message': 'private upstream detail',
          }),
        );
        await expectLater(
          resolve(service(http)),
          throwsA(
            isA<HttpRequestFailure>()
                .having((e) => e.retryable, 'retryable', code == 'upstream')
                .having(
                  (e) => e.message,
                  'safe message',
                  isNot(contains('private')),
                ),
          ),
        );
      }
    },
  );

  test(
    'HTTP authorization errors are distinct from Baidu account expiry',
    () async {
      for (final status in [401, 403, 429, 503]) {
        final http = FakeHttp(
          (_) => HttpResult(status, 'private upstream detail'),
        );
        await expectLater(
          resolve(service(http)),
          throwsA(
            isA<HttpRequestFailure>()
                .having((e) => e.status, 'status', status)
                .having(
                  (e) => e.retryable,
                  'retryable',
                  status == 429 || status == 503,
                )
                .having(
                  (e) => e.message,
                  'safe message',
                  isNot(contains('private')),
                ),
          ),
        );
      }
    },
  );

  test(
    'A valid encrypted response cannot point credentials at another domain',
    () async {
      for (final url in [
        'https://baidupcs.com.evil.invalid/file',
        'http://127.0.0.1/file',
        'file:///private',
        'https://user@fixture.baidupcs.com/file',
      ]) {
        final http = FakeHttp((call) => reply(call, {...good, 'url': url}));
        await expectLater(
          resolve(service(http)),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('下载地址无效'),
            ),
          ),
        );
      }
    },
  );

  test(
    'Cancellation before sending never transmits account credentials',
    () async {
      final http = FakeHttp();
      final scope = RequestScope()..cancel();
      await expectLater(
        scope.run(() => resolve(service(http))),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, isEmpty);
    },
  );

  test('Missing build configuration fails before a network request', () async {
    final http = FakeHttp();
    await expectLater(
      resolve(
        BaiduLinkService(http, endpoint: '', publicKey: '', accessKey: ''),
      ),
      throwsA(isA<AppException>()),
    );
    expect(http.calls, isEmpty);
  });
}

Uint8List crypt(
  bool encrypt,
  Uint8List key,
  Uint8List nonce,
  Uint8List data,
  String aad,
) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      encrypt,
      AEADParameters(
        KeyParameter(key),
        128,
        nonce,
        Uint8List.fromList(utf8.encode(aad)),
      ),
    );
  return cipher.process(data);
}

class _Transport extends FakeHttp {
  _Transport(super.respond);
  final redirects = <bool>[];
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
