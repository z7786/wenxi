import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/pan115.dart';
import 'package:asterlink/data/providers/pan115_crypto.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

final credential = Credential('115', {
  'primary': 'UID=12345_A1_fixture; CID=fixture-cid; SEID=fixture-seid',
});
const session = BrowseSession(
  platform: CloudPlatform.pan115,
  mode: BrowseMode.personal,
  title: '115',
  rootId: '0',
);
const file = CloudFile(
  id: '987654321098765432',
  name: 'large.mp4',
  size: 5000000000,
  token: 'pick123',
);
Json row(String id) => {
  'fid': id,
  'n': 'file-$id',
  's': '5000000000',
  'pc': 'pick$id',
};
Json ok([Json data = const {}]) => {'state': true, 'data': data};

class ResponseCipher extends Pan115Cipher {
  ResponseCipher(this.result);
  final Json result;
  Json? sent;
  @override
  String encode(Json payload) {
    sent = payload;
    return super.encode(payload);
  }

  @override
  Json decode(String encoded) => result;
}

class ZeroRandom implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

void main() {
  test('m115 encrypted requests match independent Go reference vectors', () {
    final cipher = Pan115Cipher(
      key: List.generate(16, (i) => i),
      random: ZeroRandom(),
    );
    expect(
      cipher.encode({'pickcode': 'pick123'}),
      'Vcf/MlC0eTWJOdJLuTVhFT/bk8gzpW1DZZn2MQcFeORxVFuZHyoEG5MEPYLso5Q+y+fNQoeYdYv+BB+2jGLQsrW+rvxXHyrnjlXuBX+PWN/lZvJsoGMDBXmnJPwJj3H7ZjV7igSRd+sUdIujVQg+RawCVDeCuZ3t7z5opcj/bCY=',
    );
    expect(
      cipher.encode({'pickcode': 'a' * 240}),
      'IhV4+Vha3gFOzzoFbgk/AO7Kghf/yb422bntUzrWPZet+3nignOqZkIMHJSqRVbtfoYxInT0qysEZDvi1zH+7RHELZKiJn4PIJ0PxbK8IhiXCGrJRXSPEV3Bgjx8IYuDFEW4ofQhlz+b3wbe7frHkCGbh7q1eZALIuR+mPDQLWQYv7boWM941+On3vl8NKiqHyIqnTaMs30GWeJclBg6h4GjsijOg7kNeR0Y5BeZJHBaI0g1V2+VMqxkTyc+BsPNFm5lXQqDerhkKI3KzOe9/kZRtkKwcuoZCboYa99SYdi67jbL3uqyOI0M4ELO/ZWPX8EVMX49rcyvV+6WjIixXFkSVSz877bPE/KNr6OM6T1/WCPgDczaFs9tgC6RQjVLo935UvrwepZ6Qd4t5VTSsvgOZPmIcG88NNHkv+N4sf+EPfO9FVGn7BafK7Zkg6qFHfuGEkW+63XmF+bA4n5HvVjqhES1Tfx05vyikjIiYf6AGGyx1vagIDJhPnOeLbya',
    );
  });

  test('115 official share hosts, password, serialization and lookalikes', () {
    for (final host in ['115.com', '115cdn.com', '115sha1.com']) {
      final link = LinkParser.parse(
        'https://$host/s/abc123?password=a1b2',
      ).single;
      expect(link.platform, CloudPlatform.pan115);
      expect(link.shareId, 'abc123');
      expect(link.passcode, 'a1b2');
      expect(ParsedLink.fromJson(link.toJson()).platform, CloudPlatform.pan115);
    }
    expect(CloudPlatform.fromHost('115.com.example.org'), isNull);
    expect(
      LinkParser.shareId(CloudPlatform.pan115, 'https://115.com/?cid=123'),
      isNull,
    );
  });

  test(
    'web capture requires all account cookies and rejects control characters',
    () {
      expect(
        LoginCredentials.plausible(CloudPlatform.pan115, credential.primary),
        isTrue,
      );
      expect(
        LoginCredentials.plausible(CloudPlatform.pan115, 'UID=12345; CID=x'),
        isFalse,
      );
      expect(
        LoginCredentials.plausible(
          CloudPlatform.pan115,
          '${credential.primary}\r\n',
        ),
        isFalse,
      );
      final target = WebLoginTarget.targets[CloudPlatform.pan115]!;
      expect(target.desktopMode, isTrue);
      expect(target.cookieDomains, contains('https://115.com'));
      expect(
        LoginCredentials.fromBrowser(
          CloudPlatform.pan115,
          cookies: [credential.primary],
        ),
        credential.primary,
      );
    },
  );

  test(
    'login fetches fresh nickname, stable identity and numeric-string quota',
    () async {
      final http = FakeHttp(
        (r) => jsonResponse(
          r.uri.host == 'my.115.com'
              ? ok({'user_id': 12345, 'user_name': '新的昵称'})
              : ok({
                  'space_info': {
                    'all_total': {'size': '1.5e12'},
                    'all_use': {'size': '12345678900'},
                  },
                }),
        ),
      );
      final result = await Pan115Connector(
        http,
      ).authenticate(credential.withFields({'nickname': '旧昵称'}));
      expect(result.credential.field('userId'), '12345');
      expect(result.account.nickname, '新的昵称');
      expect(result.account.total, 1500000000000);
      expect(result.account.used, 12345678900);
    },
  );

  test('login refuses a different account identity', () async {
    final http = FakeHttp((_) => jsonResponse(ok({'user_id': 99})));
    await expectLater(
      Pan115Connector(http).authenticate(credential),
      throwsA(isA<AppException>()),
    );
    expect(http.calls, hasLength(1));
  });

  test('expired cookie without errno is a login error', () async {
    final http = FakeHttp(
      (_) => jsonResponse({'state': false, 'error': '请先登录,后操作！'}),
    );
    await expectLater(
      Pan115Connector(http).account(credential),
      throwsA(isA<AccountLoginRequired>()),
    );
  });

  test(
    'listing paginates by actual count and preserves 64-bit IDs and sizes',
    () async {
      final http = FakeHttp((r) {
        final offset = int.parse(r.uri.queryParameters['offset']!);
        return jsonResponse({
          'state': true,
          'cid': '0',
          'count': 3,
          'data': offset == 0
              ? [
                  {'cid': '77', 'n': '目录'},
                  row(file.id),
                ]
              : [row('44')],
        });
      });
      final files = await Pan115Connector(http).list(session, '0', credential);
      expect(files, hasLength(3));
      expect(files.first.isDirectory, isTrue);
      expect(files[1].id, file.id);
      expect(files[1].size, file.size);
      expect(http.calls.last.uri.queryParameters['offset'], '2');
    },
  );

  test('listing rejects fallback root and repeated pages', () async {
    final wrong = FakeHttp(
      (_) => jsonResponse({'state': true, 'cid': '0', 'count': 0, 'data': []}),
    );
    await expectLater(
      Pan115Connector(wrong).list(session, '77', credential),
      throwsA(isA<AppException>()),
    );
    final repeat = FakeHttp(
      (_) => jsonResponse({
        'state': true,
        'cid': '0',
        'count': 9,
        'data': [row('44')],
      }),
    );
    await expectLater(
      Pan115Connector(repeat).list(session, '0', credential),
      throwsA(isA<AppException>()),
    );
    expect(repeat.calls, hasLength(2));
  });

  test(
    'large download uses encrypted app API and carries CDN authorization only',
    () async {
      final cipher = ResponseCipher({
        file.id: {
          'file_size': '${file.size}',
          'pick_code': file.token,
          'url': {'url': 'https://cdn.example.org/video'},
        },
      });
      final http = FakeHttp(
        (_) => HttpResult(
          200,
          jsonEncode(ok({'unused': true})..['data'] = 'encoded'),
          {
            'set-cookie': [
              'acw_tc=fixture-download; Path=/; HttpOnly',
              'UID=other; Path=/',
            ],
          },
        ),
      );
      final spec = await Pan115Connector(
        http,
        cipherFactory: () => cipher,
      ).download(session, file, credential);
      expect(http.calls.single.uri.path, '/app/chrome/downurl');
      expect(
        base64Decode(
              Uri.splitQueryString(http.calls.single.body as String)['data']!,
            ).length %
            128,
        0,
      );
      expect(cipher.sent, {'pickcode': file.token});
      expect(spec.expectedSize, 5000000000);
      expect(spec.headers['User-Agent'], Pan115Connector.ua);
      expect(
        http.calls.single.headers['User-Agent'],
        WebLoginTarget.desktopUserAgent,
      );
      expect(spec.headers['Cookie'], 'acw_tc=fixture-download');
      expect(spec.headers.toString(), isNot(contains('fixture-seid')));
    },
  );

  test('download refuses mismatched ID or file size', () async {
    for (final data in [
      {
        'wrong': {
          'file_size': file.size,
          'url': {'url': 'https://cdn.example.org/x'},
        },
      },
      {
        file.id: {
          'file_size': 10,
          'url': {'url': 'https://cdn.example.org/x'},
        },
      },
      {
        file.id: {'file_size': file.size, 'url': false},
      },
    ]) {
      final http = FakeHttp(
        (_) => jsonResponse({'state': true, 'data': 'encoded'}),
      );
      await expectLater(
        Pan115Connector(
          http,
          cipherFactory: () => ResponseCipher(data),
        ).download(session, file, credential),
        throwsA(isA<AppException>()),
      );
    }
  });

  test(
    '115 signed connection limits survive playback refresh and storage',
    () async {
      for (final value in ['1', '2', '8', '0', '-1', 'invalid', '']) {
        final cipher = ResponseCipher({
          file.id: {
            'file_size': file.size,
            'pick_code': file.token,
            'url': {'url': 'https://cdn.example.org/video?c=$value&f=1'},
          },
        });
        final http = FakeHttp(
          (_) => jsonResponse({'state': true, 'data': 'encoded'}),
        );
        final source = await Pan115Connector(
          http,
          cipherFactory: () => cipher,
        ).playback(session, file, credential);
        final expected = int.tryParse(value);
        final limit = expected != null && expected > 0 ? expected : null;
        expect(source.maxPlaybackConnections, limit);
        final saved = DownloadSpec.fromJson(source.toJson());
        expect(saved.maxPlaybackConnections, limit);
        expect(
          saved.copyWith(source: {'refresh': true}).maxPlaybackConnections,
          limit,
        );
      }
      expect(
        DownloadSpec.fromJson({
          'url': 'https://cdn.example.org/old-video',
          'fileName': 'old-video.mkv',
        }).maxPlaybackConnections,
        isNull,
      );
    },
  );

  test(
    'share pagination, encrypted download, and receive retain share identity',
    () async {
      final cipher = ResponseCipher({
        'fid': file.id,
        'fs': '${file.size}',
        'url': {'url': 'https://cdn.example.org/shared?c=2&f=3'},
      });
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('downurl')) {
          return jsonResponse({'state': true, 'data': 'encoded'});
        }
        return jsonResponse(
          ok({
            'count': 1,
            'list': [row(file.id)],
          }),
        );
      });
      final connector = Pan115Connector(http, cipherFactory: () => cipher);
      final link = LinkParser.parse(
        'https://115cdn.com/s/abc123?password=a1b2',
      ).single;
      final share = await connector.openShare(link, credential);
      expect(await connector.list(share, '0', credential), hasLength(1));
      final shared = await connector.playback(share, file, credential);
      expect(shared.maxPlaybackConnections, 2);
      expect(http.calls.last.uri.path, '/app/share/downurl');
      expect(http.calls.last.headers['User-Agent'], contains('115Browser'));
      expect(cipher.sent, {
        'share_code': 'abc123',
        'receive_code': 'a1b2',
        'file_id': file.id,
      });
      await connector.saveShare(share, [file], '77', credential);
      expect(Uri.splitQueryString(http.calls.last.body as String), {
        'share_code': 'abc123',
        'receive_code': 'a1b2',
        'file_id': file.id,
        'cid': '77',
      });
    },
  );

  test(
    'upload streams file to OSS and confirms exact returned file ID',
    () async {
      var reads = 0;
      final progress = <UploadProgress>[];
      final source = UploadFile(
        name: 'sample.txt',
        size: 4,
        read: (start, end) async* {
          reads++;
          yield [1, 2, 3, 4].sublist(start, end);
        },
      );
      final http = FakeHttp((r) async {
        if (r.uri.host == 'uplb.115.com') {
          expect(reads, 0);
          expect(Uri.splitQueryString(r.body as String)['target'], 'U_1_77');
          return jsonResponse({
            'host': 'https://bucket.oss-cn-shenzhen.aliyuncs.com',
            'object': 'object',
            'policy': 'policy',
            'accessid': 'access',
            'signature': 'sig',
            'callback': 'cb',
          });
        }
        if (r.body is HttpUpload) {
          expect(r.headers.containsKey('Cookie'), isFalse);
          final upload = r.body as HttpUpload;
          expect(upload.fields!['callback'], 'cb');
          expect(await upload.open().expand((c) => c).toList(), [1, 2, 3, 4]);
          return jsonResponse(ok({'file_id': '55'}));
        }
        return jsonResponse({
          'state': true,
          'cid': '77',
          'count': 2,
          'data': [
            {'fid': '22', 'n': 'sample.txt', 's': 4},
            {'fid': '55', 'n': 'sample.txt', 's': 4},
          ],
        });
      });
      final result = await Pan115Connector(
        http,
      ).upload(session, '77', source, credential, onProgress: progress.add);
      expect(result.id, '55');
      expect(reads, 1);
      expect(progress.last.phase, UploadPhase.finishing);
    },
  );

  test(
    'create folder, rename, move and recycle-bin deletion use correct IDs',
    () async {
      final http = FakeHttp(
        (r) => jsonResponse(
          r.uri.path == '/files'
              ? {'state': true, 'cid': '77', 'count': 0, 'data': []}
              : {'state': true, 'cid': '77'},
        ),
      );
      final connector = Pan115Connector(http);
      expect(
        (await connector.createFolder(session, '0', '新建目录', credential)).id,
        '77',
      );
      await connector.rename(session, file, 'renamed.mp4', credential);
      expect(
        Uri.splitQueryString(
          http.calls.last.body as String,
        )['files_new_name[${file.id}]'],
        'renamed.mp4',
      );
      await connector.move(session, [file], '77', credential);
      expect(Uri.splitQueryString(http.calls.last.body as String), {
        'pid': '77',
        'fid[0]': file.id,
      });
      await connector.delete(session, [file], credential);
      expect(http.calls.last.uri.path, '/rb/delete');
    },
  );

  test('creating share applies requested expiry and access code', () async {
    final http = FakeHttp(
      (_) => jsonResponse(ok({'share_code': 'abc123', 'receive_code': 'old1'})),
    );
    final result = await Pan115Connector(http).createShare(
      session,
      [file],
      const ShareOptions('共享', expiryDays: 7, passcode: 'new1'),
      credential,
    );
    expect(result.passcode, 'new1');
    expect(result.url, 'https://115cdn.com/s/abc123');
    expect(Uri.splitQueryString(http.calls.last.body as String), {
      'share_code': 'abc123',
      'share_duration': '7',
      'receive_code': 'new1',
    });
  });

  test('malformed cipher responses are rejected without leaking payload', () {
    final cipher = Pan115Cipher();
    for (final input in ['', 'not base64', base64Encode(List.filled(128, 0))]) {
      expect(() => cipher.decode(input), throwsA(isA<AppException>()));
    }
  });

  test(
    'upload policy rejects explicit errors even with complete policy fields',
    () async {
      final http = FakeHttp(
        (_) => jsonResponse({
          'state': false,
          'errno': 99,
          'object': 'x',
          'accessid': 'x',
          'host': 'https://bucket.oss-cn-shenzhen.aliyuncs.com',
          'policy': 'x',
          'signature': 'x',
          'callback': 'x',
        }),
      );
      final source = UploadFile(
        name: 'sample.txt',
        size: 1,
        read: (_, _) =>
            throw StateError('File must not be read before initialization'),
      );
      await expectLater(
        Pan115Connector(http).upload(session, '0', source, credential),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'share agreement requirement is explained without silently accepting it',
    () async {
      final http = FakeHttp(
        (_) => jsonResponse({
          'state': false,
          'errno': 4100001,
          'error': '需要先同意分享协议',
        }),
      );
      await expectLater(
        Pan115Connector(
          http,
        ).createShare(session, [file], const ShareOptions('test'), credential),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('115 官网同意分享协议'),
          ),
        ),
      );
      expect(http.calls, hasLength(1));
    },
  );
}
