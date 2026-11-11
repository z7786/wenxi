import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/data/uploads/upload_io.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/transfer_md5.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/rapid_transfer.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const hash = '900150983cd24fb0d6963f7d28e17f72';
const source = CloudFile(
  id: '42',
  name: 'sample.bin',
  size: 3,
  parentId: '/',
  token: '/sample.bin',
);
BrowseSession session(CloudPlatform p) => BrowseSession(
  platform: p,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '0',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final hit in [true, false]) {
    test('Guangya hash-only transfer hit=$hit sends no payload', () async {
      final vault = await tokenVault(CloudPlatform.guangya);
      final http = FakeHttp((r) {
        expect(r.body is HttpUpload, false);
        switch (r.uri.path) {
          case '/nd.bizuserres.s/v1/get_res_center_token':
            expect(r.json.obj('res')['md5'], hash);
            expect(r.json.obj('res')['fileSize'], 3);
            return guangyaResponse({'taskId': 'task'}, code: hit ? 156 : 0);
          case '/nd.bizuserres.s/v1/file/get_info_by_task_id':
            return guangyaResponse({'fileId': 'saved'});
          case '/userres/v1/file/get_file_list':
            return guangyaResponse({
              'list': [
                {
                  'fileId': 'saved',
                  'fileName': 'sample.bin',
                  'fileSize': 3,
                  'md5': hash,
                },
              ],
              'total': 1,
            });
          default:
            throw StateError('Unexpected endpoint ${r.uri.path}');
        }
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      final result = await connector.rapidTransfer(
        tokenPersonal(CloudPlatform.guangya),
        'root',
        RapidTransferFile(name: 'sample.bin', size: 3, md5: hash),
        vault.credential(CloudPlatform.guangya)!,
      );
      expect(result.reused, hit);
    });
  }
  test(
    'relay verified hashes avoid re-reading during upload and survive guards',
    () async {
      var reads = 0, validations = 0;
      final input = UploadFile(
        name: 'sample.bin',
        size: 3,
        read: (start, end) {
          reads++;
          return Stream.value(utf8.encode('abc').sublist(start, end));
        },
        validate: () async {
          validations++;
        },
        verifiedHashes: {
          'md5': hash,
          'sha1': sha1.convert(utf8.encode('abc')).toString(),
        },
      );
      final io = UploadIO(FakeHttp(), input.guarded(() {}), null);
      expect(await io.digest(md5), hash);
      expect(
        await io.digest(sha1),
        sha1.convert(utf8.encode('abc')).toString(),
      );
      expect(reads, 0);
      expect(validations, 2);
      expect(
        await io.digest(md5, start: 1),
        md5.convert(utf8.encode('bc')).toString(),
      );
      expect(reads, 1);
    },
  );
  for (final reuse in [true, false]) {
    test('123 hash-only request reuse=$reuse never sends file bytes', () async {
      final store = StateStore.memory(), vault = Vault(StateStore.memory());
      final c = Credential('fixture', {
        'authType': 'webToken',
        'primary': 'test-token',
      });
      await vault.putCredential(CloudPlatform.pan123, c);
      final http = FakeHttp((r) {
        expect(r.uri.path, '/b/api/file/upload_request');
        expect(r.method, 'POST');
        expect(r.headers['authorization'], 'Bearer test-token');
        expect(r.json['etag'], hash);
        expect(r.json['duplicate'], 1);
        expect(r.json['parentFileId'], 12);
        return jsonResponse({
          'code': 0,
          'data': {
            'Reuse': reuse,
            'Info': {'FileId': 42, 'Size': 3, 'Etag': hash, 'ParentFileId': 12},
          },
        });
      });
      final result = await Pan123Connector(http, vault).rapidTransfer(
        session(CloudPlatform.pan123),
        '12',
        RapidTransferFile(name: 'sample.bin', size: 3, md5: hash),
        c,
      );
      expect(result.reused, reuse);
      expect(http.calls.length, 1);
      expect(store.data['uploadTasks'], null);
    });
  }
  test('123 rejects mismatched successful receipt', () async {
    final vault = Vault(StateStore.memory());
    final c = Credential('fixture', {
      'authType': 'webToken',
      'primary': 'test-token',
    });
    await vault.putCredential(CloudPlatform.pan123, c);
    final http = FakeHttp(
      (r) => jsonResponse({
        'code': 0,
        'data': {
          'Reuse': true,
          'Info': {'FileId': 42, 'Size': 300, 'Etag': hash, 'ParentFileId': 12},
        },
      }),
    );
    await expectLater(
      Pan123Connector(http, vault).rapidTransfer(
        session(CloudPlatform.pan123),
        '12',
        RapidTransferFile(name: 'sample.bin', size: 3, md5: hash),
        c,
      ),
      throwsA(isA<AppException>()),
    );
    expect(http.calls.length, 1);
  });
  test(
    'MD5 extraction rejects ETag, malformed base64 and non-content headers',
    () {
      expect(
        md5FromHeaders(
          const HttpResult(200, '', {
            'etag': [hash],
          }),
        ),
        null,
      );
      expect(
        md5FromHeaders(
          const HttpResult(200, '', {
            'content-md5': ['bad'],
          }),
        ),
        null,
      );
      expect(
        md5FromHeaders(
          HttpResult(200, '', {
            'content-md5': [
              base64Encode(md5.convert(utf8.encode('abc')).bytes),
            ],
          }),
        ),
        hash,
      );
    },
  );
  for (final reuse in [true, false]) {
    test('Tianyi signed MD5 transfer reuse=$reuse verifies saved file', () async {
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('getUserBriefInfo.action')) {
          expect(r.headers['Cookie'], 'COOKIE_LOGIN_USER=fixture');
          return jsonResponse({'res_code': 0, 'sessionKey': 'web-session'});
        }
        if (r.uri.path.endsWith('getAccessTokenBySsKey.action')) {
          expect(r.headers['AppKey'], '8025431004');
          return jsonResponse({'res_code': 0, 'accessToken': 'pc-access'});
        }
        if (r.uri.path.endsWith('getSessionForPC.action')) {
          expect(r.uri.queryParameters['appId'], '8025431004');
          expect(r.uri.queryParameters['accessToken'], 'pc-access');
          return jsonResponse({
            'res_code': 0,
            'sessionKey': 'pc-session',
            'sessionSecret': 'secret',
          });
        }
        if (r.method == 'POST') {
          final date = r.headers['Date'];
          final sign = Hmac(sha1, utf8.encode('secret'))
              .convert(
                utf8.encode(
                  'SessionKey=pc-session&Operate=POST&RequestURI=${r.uri.path}&Date=$date',
                ),
              )
              .toString()
              .toUpperCase();
          expect(r.headers['Signature'], sign);
          final body = Uri.splitQueryString(r.body! as String);
          if (r.uri.path.endsWith('createUploadFile.action')) {
            expect(body['md5'], hash);
            expect(body['size'], '3');
            expect(body['parentFolderId'], '12');
            return jsonResponse({
              'res_code': 0,
              'uploadFileId': 'task-42',
              'fileDataExists': reuse ? 1 : 0,
              'fileCommitUrl': 'https://upload.cloud.189.cn/commitFile.action',
            });
          }
          expect(r.uri.path, '/commitFile.action');
          expect(body['opertype'], '1');
          expect(body['uploadFileId'], 'task-42');
          return const HttpResult(200, '<file><id>42</id></file>');
        }
        expect(reuse, true);
        expect(r.uri.path, '/api/open/file/listFiles.action');
        return jsonResponse({
          'res_code': 0,
          'fileListAO': {
            'count': 1,
            'folderList': [],
            'fileList': [
              {'id': '42', 'name': 'sample.bin', 'size': 3, 'md5': hash},
            ],
          },
        });
      });
      final result = await TianyiConnector(http).rapidTransfer(
        session(CloudPlatform.tianyi),
        '12',
        RapidTransferFile(name: 'sample.bin', size: 3, md5: hash),
        Credential('fixture', {'primary': 'COOKIE_LOGIN_USER=fixture'}),
      );
      expect(result.reused, reuse);
      expect(http.calls.where((r) => r.method == 'PUT'), isEmpty);
      expect(http.calls.any((r) => r.uri.path == '/commitFile.action'), reuse);
    });
  }
  test(
    'Baidu metadata/probe uses original file without link service or transfer',
    () async {
      final http = FakeHttp((r) {
        if (r.uri.path == '/api/filemetas') {
          expect(r.uri.queryParameters['target'], encoded(['/sample.bin']));
          expect(r.uri.queryParameters['origin'], 'dlna');
          return jsonResponse({
            'errno': 0,
            'info': [
              {
                'fs_id': '42',
                'size': 3,
                'isdir': 0,
                'md5': 'f' * 32,
                'dlink': 'https://d.pcs.baidu.com/file',
              },
            ],
          });
        }
        expect(r.method, 'HEAD');
        return const HttpResult(200, '', {
          'content-length': ['3'],
          'content-md5': [hash],
        });
      });
      final result = await BaiduConnector(http).transferMd5(
        session(CloudPlatform.baidu),
        source,
        Credential('fixture', {'primary': 'BDUSS=fixture'}),
      );
      expect(result, hash);
      expect(http.calls.length, 2);
      expect(http.calls.any((r) => r.method == 'POST'), false);
    },
  );
  test(
    'probe refuses cross-domain redirects before sending credentials',
    () async {
      final http = FakeHttp(
        (r) => const HttpResult(302, '', {
          'location': ['https://attacker.example/file'],
        }),
      );
      expect(
        await probeTransferMd5(http, 'https://pcs.baidu.com/file', {
          'Cookie': 'BDUSS=fixture',
        }, 3),
        null,
      );
      expect(http.calls.length, 1);
    },
  );
}
