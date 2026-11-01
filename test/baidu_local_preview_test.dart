import 'dart:convert';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu_local_preview.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

const _device = {
  'id': '0123456789ABCDEF0123456789ABCDEF|0',
  'model': 'Test Phone 中文',
  'osVersion': '14',
  'downloadVersion': '13.15.4',
  'networkType': 'wifi',
  'networkSubtype': 0,
};
Future<Object> _resolve(
  BaiduLocalPreview preview, {
  String cookie = 'BDUSS=fixture',
  String path = '/视频/原始文件.bin',
  String fileId = '123',
}) => preview.resolve(
  cookie: cookie,
  path: path,
  fileId: fileId,
  appId: '250528',
  device: _device,
);

void main() {
  test(
    'Preview activation, RC4 session and signature match the original protocol',
    () async {
      final http = FakeHttp((r) {
        expect(r.uri.scheme, 'https');
        expect(r.headers['Cookie'], 'BDUSS=fixture');
        final q = r.uri.queryParameters;
        if (r.uri.path == '/rest/2.0/xpan/nas') {
          return jsonResponse({'errno': 0, 'vip_type': 0});
        }
        if (r.uri.host == 'passport.baidu.com') {
          final f = Uri.splitQueryString(r.body as String);
          final signature = f.remove('sig');
          final keys = f.keys.toList()..sort();
          final content = form({for (final key in keys) key: f[key]});
          expect(
            signature,
            md5
                .convert(
                  utf8.encode(
                    '$content&sign_key=0c2d71b9d3aee3947c59a7480df05e85',
                  ),
                )
                .toString(),
          );
          expect(f['bduss'], 'fixture');
          expect(f['cuid'], _device['id']);
          expect(
            r.headers['User-Agent'],
            'tpl:netdisk;android_sapi_v9.0.0.0.3',
          );
          return jsonResponse({'errno': 0, 'uid': '123456789'});
        }
        if (r.uri.path == '/api/report/user') {
          expect(q['channel'], 'android_14_Test Phone 中文_bd-netdisk_1');
          expect(q['action'], 'ANDROID_ACTIVE_FRONTDESK');
          // Fixture encrypted with an independent RC4 implementation.
          return jsonResponse({
            'errno': 0,
            'uinfo': 'RLs/VygyH/SSzONO6GIxAXLEsLVtm3s=',
          });
        }
        expect(r.uri.host, 'd.pcs.baidu.com');
        expect(q['method'], 'locatedownload');
        expect(q['use'], '1');
        expect(q['apn_id'], '1_0');
        expect(q['queryfree'], '2');
        final inner = sha1.convert(utf8.encode('fixture')).toString();
        expect(
          q['rand'],
          sha1
              .convert(
                utf8.encode(
                  '${inner}123456789preview-session-fixture${q['time']}${_device['id']}',
                ),
              )
              .toString(),
        );
        return jsonResponse({
          'urls': [
            {'url': 'http://fixture.baidupcs.com/original'},
            {'url': 'https://fixture.baidupcs.com/original', 'encrypt': 0},
          ],
        });
      });
      final result = await BaiduLocalPreview(http).resolve(
        cookie: 'BDUSS=fixture',
        path: '/视频/原始文件.bin',
        fileId: '123',
        appId: '250528',
        device: _device,
      );
      expect(result.preview, isTrue);
      expect(result.url, 'https://fixture.baidupcs.com/original');
      expect(http.calls, hasLength(4));
    },
  );
  test(
    'Failed preview activation retains original ordinary locate fallback',
    () async {
      final http = FakeHttp((r) {
        if (r.uri.host == 'passport.baidu.com') {
          return const HttpResult(503, 'unavailable');
        }
        if (r.uri.host == 'd.pcs.baidu.com') {
          expect(r.uri.queryParameters.containsKey('use'), isFalse);
          return jsonResponse({
            'urls': [
              {'url': 'https://fixture.baidupcs.com/file'},
            ],
          });
        }
        return jsonResponse({'errno': 0});
      });
      final result = await BaiduLocalPreview(http).resolve(
        cookie: 'BDUSS=fixture',
        path: '/file',
        fileId: '123',
        appId: '250528',
        device: _device,
      );
      expect(result.profile, 'baidu');
      expect(http.calls.any((r) => r.uri.host == 'd.pcs.baidu.com'), isTrue);
    },
  );
  test(
    'Legacy file ID metadata keeps large IDs and rejects unrelated hosts',
    () async {
      for (final url in [
        'https://fixture.baidupcs.com/file',
        'https://baidu.com.evil.invalid/file',
      ]) {
        final http = FakeHttp((r) {
          expect(jsonDecode(r.uri.queryParameters['fsids']!), [
            '9007199254740993',
          ]);
          return jsonResponse({
            'errno': 0,
            'info': [
              {'fs_id': '9007199254740993', 'dlink': url},
            ],
          });
        });
        final action = _resolve(
          BaiduLocalPreview(http),
          path: '',
          fileId: '9007199254740993',
        );
        if (url.contains('evil')) {
          await expectLater(action, throwsA(isA<AppException>()));
        } else {
          await action;
        }
      }
    },
  );
  test('Authentication expiry is never hidden by other local routes', () async {
    for (final response in [
      jsonResponse({'errno': -6}),
      const HttpResult(401, 'unauthorized'),
    ]) {
      final http = FakeHttp((_) => response);
      await expectLater(
        _resolve(BaiduLocalPreview(http)),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls, hasLength(1));
    }
  });
  test(
    'Concurrent local calls keep account and device parameters isolated',
    () async {
      final accounts = <String>[];
      final http = FakeHttp((r) {
        accounts.add(r.headers['Cookie']!);
        return jsonResponse({
          'errno': 0,
          'info': [
            {'fs_id': '123', 'dlink': 'https://fixture.baidupcs.com/file'},
          ],
        });
      });
      final preview = BaiduLocalPreview(http);
      await Future.wait([
        _resolve(preview, cookie: 'BDUSS=alice', path: ''),
        _resolve(preview, cookie: 'BDUSS=bob', path: ''),
      ]);
      expect(accounts, unorderedEquals(['BDUSS=alice', 'BDUSS=bob']));
    },
  );
  test(
    'Cancellation during preview activation prevents any fallback request',
    () async {
      final scope = RequestScope();
      final http = FakeHttp((r) {
        if (r.uri.host == 'passport.baidu.com') scope.cancel();
        return jsonResponse({'errno': 0, 'uid': '123456789'});
      });
      await expectLater(
        scope.run(() => _resolve(BaiduLocalPreview(http))),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(2));
    },
  );
}
