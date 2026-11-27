import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const personal = BrowseSession(
  platform: CloudPlatform.baidu,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: '/',
);
const file = CloudFile(
  id: '123',
  name: '测试 + &.txt',
  token: '/目录 + &/测试 + &.txt',
);
const folder = CloudFile(
  id: '456',
  name: '文件夹',
  token: '/文件夹',
  isDirectory: true,
);
Credential credential() => Credential('fixture', {'primary': 'BDUSS=fixture'});

FakeHttp shareHttp() => FakeHttp((r) {
  expect(r.uri.path, '/share/pset');
  final fields = Uri.splitQueryString(r.body as String);
  // The upstream private-share endpoint rejects an empty or invalid code.
  if (!RegExp(r'^[A-Za-z0-9]{4}$').hasMatch(fields['pwd'] ?? '')) {
    return jsonResponse({'errno': 2});
  }
  return jsonResponse({
    'errno': 0,
    'shorturl': 'https://pan.baidu.com/s/1fixture',
  });
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final code in <String?>[null, '', '   ']) {
    for (final files in [
      [file],
      [file, folder],
      [folder],
    ]) {
      test(
        'Blank code ($code), ${files.length} selected items remains usable',
        () async {
          final http = shareHttp();
          final result = await BaiduConnector(http).createShare(
            personal,
            files,
            ShareOptions('fixture', passcode: code),
            credential(),
          );
          final request = http.calls.single;
          final body = Uri.splitQueryString(request.body as String);
          expect(body['schannel'], '4');
          expect(body['pwd'], matches(r'^[A-Za-z0-9]{4}$'));
          expect(
            jsonDecode(body['path_list']!),
            files.map((f) => f.token).toList(),
          );
          expect(result.passcode, body['pwd']);
          expect(LinkParser.parse(result.text).single.passcode, body['pwd']);
        },
      );
    }
  }

  for (final days in <int?>[null, 1, 7, 30]) {
    test(
      'Manual mixed-case code and $days-day expiry survive creation',
      () async {
        final http = shareHttp();
        final result = await BaiduConnector(http).createShare(
          personal,
          [file],
          ShareOptions('分享标题', expiryDays: days, passcode: ' aB12 '),
          credential(),
        );
        final body = Uri.splitQueryString(http.calls.single.body as String);
        expect(body['pwd'], 'aB12');
        expect(body['period'], '${days ?? 0}');
        expect(result.passcode, 'aB12');
        expect(result.title, '分享标题');
      },
    );
  }

  for (final code in ['abc', 'abcde', 'a-12', '中文密码', 'ab\n1']) {
    test(
      'Invalid extraction code is rejected before any request: $code',
      () async {
        final http = shareHttp();
        await expectLater(
          BaiduConnector(http).createShare(
            personal,
            [file],
            ShareOptions('x', passcode: code),
            credential(),
          ),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('4 位'),
            ),
          ),
        );
        expect(http.calls, isEmpty);
      },
    );
  }

  test(
    'A failed share creation is never replayed by read retry policy',
    () async {
      final http = FakeHttp((_) => jsonResponse({'errno': 2}, 503));
      var retries = 0;
      final retry = ReadRetryScope(
        retries: 3,
        checkpoint: () {},
        wait: (_) async => retries++,
      );
      await expectLater(
        retry.run(
          () => BaiduConnector(RetryingJsonHttp(http)).createShare(
            personal,
            [file],
            const ShareOptions('x'),
            credential(),
          ),
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
      expect(retries, 0);
    },
  );

  test(
    'Non-JSON unauthorized response retains the account-login error',
    () async {
      final http = FakeHttp((_) => const HttpResult(401, 'unauthorized'));
      await expectLater(
        BaiduConnector(
          http,
        ).createShare(personal, [file], const ShareOptions('x'), credential()),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls, hasLength(1));
    },
  );

  test('Missing file paths are rejected without creating a share', () async {
    final http = shareHttp();
    for (final files in <List<CloudFile>>[
      [],
      [const CloudFile(id: '123', name: 'x')],
    ]) {
      await expectLater(
        BaiduConnector(
          http,
        ).createShare(personal, files, const ShareOptions('x'), credential()),
        throwsA(isA<AppException>()),
      );
    }
    expect(http.calls, isEmpty);
  });
}
