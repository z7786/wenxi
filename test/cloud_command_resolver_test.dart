import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_command_resolver.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

CloudCommandKeys get fixtureCommandKeys =>
    CloudCommandKeys(quark: 'A' * 88, uc: 'B' * 24);

HttpResult commandResponse(CloudPlatform platform, {String code = 'A%2B+B'}) {
  if (platform == CloudPlatform.xunlei) {
    return jsonResponse({
      'ext': {'kouling_type': 'share_page'},
      'location': 'https://pan.xunlei.com/s/fixture?pwd=1234',
    });
  }
  final quark = platform == CloudPlatform.quark;
  final share = {'pwd_id': 'fixture', 'passcode': code};
  return jsonResponse({
    'success': true,
    'code': 'OK',
    'data': {
      'androidUrl': Uri(
        scheme: quark ? 'quark' : 'uc',
        host: 'share',
        queryParameters: {
          quark ? 'qk_params' : 'clouddrive_params': jsonEncode(
            quark
                ? {
                    'params': {'query': share},
                  }
                : {'additionProps': share},
          ),
        },
      ).toString(),
    },
  });
}

void main() {
  test(
    'Signatures match independently generated vectors and preserve whitespace',
    () {
      final resolver = CloudCommandResolver(
        FakeHttp(),
        keys: fixtureCommandKeys,
      );
      final q = resolver.buildRequest(
        CloudPlatform.quark,
        '  咐置松君杂货铺叩苓\n',
        1700000000000,
      );
      expect(q['sign'], '2ee161cbfb0130221d5ee15564630fcbb5cd8baaa43b');
      expect(q['clipboard'], '  咐置松君杂货铺叩苓\n');
      expect(q['identifier'], '');
      expect(q['shareSecret'], '');
      final u = resolver.buildRequest(
        CloudPlatform.uc,
        '  ~U_Cfc773YARWW~\n',
        1700000000000,
      );
      expect(u['sign'], '03e9bca7c67bde20413b418c5dacbf0c29bb7da82521');
      expect(u['clipboard'], '  ~U_Cfc773YARWW~\n');
      expect(u['identifier'], '');
      expect(u['shareSecret'], '');
      expect(u['kps'], '');
    },
  );

  test(
    'Quark short tokens preserve the clipboard and use the correct signature',
    () {
      final resolver = CloudCommandResolver(
        FakeHttp(),
        keys: fixtureCommandKeys,
      );
      const clipboard = '  分享文件 /~62003YrHLe~:/\n';
      final body = resolver.buildRequest(
        CloudPlatform.quark,
        clipboard,
        1700000000000,
      );
      expect(body['clipboard'], clipboard);
      expect(body['identifier'], '');
      expect(body['shareSecret'], '');
      expect(body['sign'], '2ee143fc94fbf48728a1a471d345ee19299e44d23564');
    },
  );

  test(
    'Quark short tokens resolve through the selected official service',
    () async {
      final http = FakeHttp((r) => commandResponse(CloudPlatform.quark));
      final link = await CloudCommandResolver(
        http,
        keys: fixtureCommandKeys,
      ).resolve(CloudPlatform.quark, '/~62003YrHLe~:/');
      expect(link.platform, CloudPlatform.quark);
      expect(link.url, 'https://pan.quark.cn/s/fixture');
      expect(link.passcode, 'A%2B+B');
      expect(http.calls, hasLength(1));
      expect(http.calls.single.uri.host, 'utoken2.quark.cn');
      expect(http.calls.single.json['identifier'], '');
      expect(http.calls.single.json['shareSecret'], '');
    },
  );

  for (final input in [
    '新格式+_令牌/123，打开夸克查看',
    '/~a~:/',
    '/~62003YrHLe~:/ /~62003YrHLe~:/',
    '咐置一个叩苓 /~62003YrHLe~:/',
    '咐置一个叩苓 咐置另一个叩苓',
  ]) {
    test(
      'Quark lets the provider interpret the complete clipboard: $input',
      () async {
        final http = FakeHttp((_) => commandResponse(CloudPlatform.quark));
        final link = await CloudCommandResolver(
          http,
          keys: fixtureCommandKeys,
        ).resolve(CloudPlatform.quark, input);
        expect(link.shareId, 'fixture');
        expect(http.calls, hasLength(1));
        expect(http.calls.single.json['clipboard'], input);
        expect(http.calls.single.json['identifier'], '');
        expect(http.calls.single.json['shareSecret'], '');
      },
    );
  }

  for (final platform in CloudCommandResolver.platforms.where(
    (p) => p != CloudPlatform.c139,
  )) {
    test(
      '${platform.key} only contacts the selected provider and returns a reusable share',
      () async {
        final http = FakeHttp((r) => commandResponse(platform));
        final resolver = CloudCommandResolver(http, keys: fixtureCommandKeys);
        final text = platform == CloudPlatform.quark
            ? '咐置松君杂货铺叩苓'
            : '觸三位一体煎饼就緒';
        final link = await resolver.resolve(platform, text);
        expect(link.platform, platform);
        expect(link.shareId, 'fixture');
        expect(
          link.passcode,
          platform == CloudPlatform.xunlei ? '1234' : 'A%2B+B',
        );
        expect(link.source, contains(link.url));
        expect(http.calls, hasLength(1));
        expect(
          http.calls.single.uri.host,
          platform == CloudPlatform.xunlei
              ? 'api-shoulei-ssl.xunlei.com'
              : 'utoken2.${platform.name}.cn',
        );
        expect(http.calls.single.headers.containsKey('Cookie'), isFalse);
        if (platform != CloudPlatform.xunlei) {
          expect(http.calls.single.json['clipboard'], text);
        }
      },
    );
  }

  for (final platform in CloudCommandResolver.platforms.where(
    (p) => p != CloudPlatform.c139,
  )) {
    test(
      '${platform.key} sends new formats without a local character filter',
      () async {
        final input = '新口令 @token_123-🪁 ${'a' * 100}';
        final http = FakeHttp((_) => commandResponse(platform));
        final link = await CloudCommandResolver(
          http,
          keys: fixtureCommandKeys,
        ).resolve(platform, input);
        expect(link.platform, platform);
        expect(http.calls, hasLength(1));
        expect(
          platform == CloudPlatform.xunlei
              ? http.calls.single.uri.queryParameters['wd']
              : http.calls.single.json['clipboard'],
          input,
        );
      },
    );

    test(
      '${platform.key} still rejects empty or excessive input before networking',
      () async {
        final http = FakeHttp();
        for (final input in [
          '',
          ' \n ',
          'x' * (CloudCommandResolver.maximumLength + 1),
        ]) {
          await expectLater(
            CloudCommandResolver(
              http,
              keys: fixtureCommandKeys,
            ).resolve(platform, input),
            throwsA(isA<AppException>()),
          );
        }
        expect(http.calls, isEmpty);
      },
    );
  }

  test(
    'Xunlei retries the exact text when punctuation belongs to a new token',
    () async {
      const command = 'new_token!';
      final http = FakeHttp(
        (r) => r.uri.queryParameters['wd'] == command
            ? commandResponse(CloudPlatform.xunlei)
            : jsonResponse({
                'ext': {'kouling_type': 'search'},
              }),
      );
      final link = await CloudCommandResolver(
        http,
      ).resolve(CloudPlatform.xunlei, command);
      expect(link.shareId, 'fixture');
      expect(http.calls.map((r) => r.uri.queryParameters['wd']), [
        'new_token',
        command,
      ]);
    },
  );

  test(
    'Quoted legacy Xunlei commands still resolve with one request',
    () async {
      final http = FakeHttp((_) => commandResponse(CloudPlatform.xunlei));
      final link = await CloudCommandResolver(
        http,
      ).resolve(CloudPlatform.xunlei, '【张三丰资源】');
      expect(link.shareId, 'fixture');
      expect(http.calls, hasLength(1));
      expect(http.calls.single.uri.queryParameters['wd'], '张三丰资源');
    },
  );

  test('Xunlei network errors do not trigger a second text variant', () async {
    final http = FakeHttp((_) => const HttpResult(503, '{}'));
    await expectLater(
      CloudCommandResolver(http).resolve(CloudPlatform.xunlei, '【口令】'),
      throwsA(isA<AppException>()),
    );
    expect(http.calls, hasLength(1));
  });

  test(
    'Failure on a selected provider never queries another provider',
    () async {
      final http = FakeHttp(
        (r) => jsonResponse({'success': false, 'code': 'INVALID'}),
      );
      await expectLater(
        CloudCommandResolver(
          http,
          keys: fixtureCommandKeys,
        ).resolve(CloudPlatform.uc, '中文口令'),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
      expect(http.calls.single.uri.host, 'utoken2.uc.cn');
    },
  );

  test('Missing build material does not send requests', () async {
    final http = FakeHttp();
    await expectLater(
      CloudCommandResolver(
        http,
        keys: const CloudCommandKeys(quark: '', uc: ''),
      ).resolve(CloudPlatform.uc, '中文口令'),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      CloudCommandResolver(
        http,
        keys: const CloudCommandKeys(quark: '', uc: ''),
      ).resolve(CloudPlatform.quark, '任意新格式'),
      throwsA(isA<AppException>()),
    );
    expect(http.calls, isEmpty);
  });

  test('Malformed response and non-share Xunlei result are rejected', () async {
    final http = FakeHttp(
      (r) => jsonResponse({
        'success': true,
        'code': 'OK',
        'data': {'androidUrl': 'https://example.test/'},
      }),
    );
    await expectLater(
      CloudCommandResolver(
        http,
        keys: fixtureCommandKeys,
      ).resolve(CloudPlatform.uc, '中文口令'),
      throwsA(isA<AppException>()),
    );
    final search = FakeHttp(
      (r) => jsonResponse({
        'ext': {'kouling_type': 'search'},
        'location': 'https://example.test/',
      }),
    );
    await expectLater(
      CloudCommandResolver(search).resolve(CloudPlatform.xunlei, '中文口令'),
      throwsA(isA<AppException>()),
    );
  });

  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    test(
      '${platform.key} accepts an official web share response and preserves its code',
      () async {
        final host = platform == CloudPlatform.quark
            ? 'pan.quark.cn'
            : 'drive.uc.cn';
        final http = FakeHttp(
          (r) => jsonResponse({
            'success': true,
            'code': 'OK',
            'data': {
              'androidUrl': 'https://$host/s/fixture?pwd=a1B2&way=kouling',
            },
          }),
        );
        final link = await CloudCommandResolver(http, keys: fixtureCommandKeys)
            .resolve(
              platform,
              platform == CloudPlatform.quark
                  ? '/~62003YrHLe~:/'
                  : '~U_Cfc773YARWW~',
            );
        expect(link.platform, platform);
        expect(link.shareId, 'fixture');
        expect(link.passcode, 'a1B2');
        expect(http.calls, hasLength(1));
      },
    );
  }

  test(
    'An official iOS web share can be used if the Android target is unsupported',
    () {
      final link = CloudCommandResolver.decodeResponse(CloudPlatform.quark, {
        'success': true,
        'code': 'OK',
        'data': {
          'androidUrl': 'https://example.test/page',
          'iosUrl': 'https://pan.quark.cn/s/fixture?pwd=a1B2',
        },
      });
      expect(link.shareId, 'fixture');
      expect(link.passcode, 'a1B2');
    },
  );

  for (final target in [
    'https://example.test/?url=https://pan.quark.cn/s/fixture',
    'https://drive.uc.cn/s/fixture',
    'https://pan.quark.cn@invalid.test/s/fixture',
    'https://pan.quark.cn/list',
  ]) {
    test('Quark does not open unsupported command targets: $target', () {
      expect(
        () => CloudCommandResolver.decodeResponse(CloudPlatform.quark, {
          'success': true,
          'code': 'OK',
          'data': {'androidUrl': target},
        }),
        throwsA(isA<AppException>()),
      );
    });
  }

  test('Cancelled request cannot return a late share', () async {
    final scope = RequestScope();
    final http = FakeHttp((r) {
      scope.cancel();
      return commandResponse(CloudPlatform.uc);
    });
    await expectLater(
      scope.run(
        () => CloudCommandResolver(
          http,
          keys: fixtureCommandKeys,
        ).resolve(CloudPlatform.uc, '中文口令'),
      ),
      throwsA(isA<AppException>()),
    );
  });
}
