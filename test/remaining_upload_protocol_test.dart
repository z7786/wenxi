import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/providers/xunlei.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

UploadFile _source(Uint8List bytes) => UploadFile(
  name: 'sample.txt',
  size: bytes.length,
  read: (start, end) => Stream.value(Uint8List.sublistView(bytes, start, end)),
);

void main() {
  for (final mode in [
    'switch-node',
    'http-unavailable',
    'http-forbidden',
    'cancel',
    'untrusted-node',
  ]) {
    test('Baidu upload node handling: $mode', () async {
      final scope = RequestScope(), bytes = Uint8List.fromList([11, 22, 33]);
      final sent = <RecordedRequest>[];
      var commits = 0;
      final http = FakeHttp((r) async {
        if (r.uri.path.endsWith('/precreate')) {
          return jsonResponse({
            'errno': 0,
            'uploadid': 'same-task',
            'return_type': 1,
            'block_list': [0],
          });
        }
        if (r.uri.queryParameters['method'] == 'locateupload') {
          return jsonResponse({
            'error_code': 0,
            'servers': [
              {'server': 'http://insecure.pcs.baidu.com'},
              {'server': 'https://pcs.baidu.com.attacker.example'},
              {'server': 'https://user@upload.pcs.baidu.com'},
              if (mode != 'untrusted-node') ...[
                {'server': 'https://first.pcs.baidu.com'},
                {'server': 'https://second.pcs.baidu.com'},
              ],
            ],
          });
        }
        if (r.body is HttpUpload) {
          sent.add(r);
          expect(
            await (r.body as HttpUpload).open().expand((c) => c).toList(),
            bytes,
          );
          if (sent.length == 1) {
            if (mode == 'http-unavailable') return const HttpResult(503, '');
            if (mode == 'http-forbidden') return const HttpResult(403, '');
            if (mode == 'cancel') scope.cancel();
            throw const HttpRequestFailure(
              'node unavailable',
              kind: 'connectionError',
              retryable: true,
            );
          }
          expect(r.uri.host, 'second.pcs.baidu.com');
          expect(r.uri.queryParameters['uploadid'], 'same-task');
          expect(r.uri.queryParameters['partseq'], '0');
          return jsonResponse({'md5': md5.convert(bytes).toString()});
        }
        if (r.uri.path == '/api/create') {
          commits++;
          return jsonResponse({'errno': 0, 'fs_id': '99'});
        }
        expect(r.uri.path, '/api/list');
        return jsonResponse({
          'errno': 0,
          'list': [
            {
              'fs_id': '99',
              'path': '/sample.txt',
              'server_filename': 'sample.txt',
              'isdir': 0,
              'size': 3,
            },
          ],
        });
      });
      const session = BrowseSession(
        platform: CloudPlatform.baidu,
        mode: BrowseMode.personal,
        title: 'files',
        rootId: '/',
      );
      final upload = scope.run(
        () => BaiduConnector(http).upload(
          session,
          '/',
          _source(bytes),
          Credential('fixture', {'primary': 'BDUSS=fixture'}),
        ),
      );
      if (mode == 'switch-node' || mode == 'http-unavailable') {
        expect((await upload).id, '99');
        expect(sent, hasLength(2));
        expect(commits, 1);
      } else {
        await expectLater(upload, throwsA(isA<AppException>()));
        expect(commits, 0);
        expect(
          sent,
          hasLength(mode == 'cancel' || mode == 'http-forbidden' ? 1 : 0),
        );
      }
    });
  }
  for (final badHash in [false, true]) {
    test(
      'Baidu validates every uploaded block before committing, badHash=$badHash',
      () async {
        final bytes = Uint8List(4 * 1024 * 1024 + 3)
          ..setRange(4 * 1024 * 1024, 4 * 1024 * 1024 + 3, [1, 2, 3]);
        var commits = 0, parts = 0;
        final http = FakeHttp((r) async {
          if (r.uri.path.endsWith('/gettemplatevariable')) {
            return jsonResponse({
              'errno': 0,
              'result': {'bdstoken': 'fixture-csrf'},
            });
          }
          if (r.uri.path.endsWith('/precreate')) {
            final form = Uri.splitQueryString(r.body as String);
            expect(form['path'], '/folder/sample.txt');
            expect(form['rtype'], '0');
            expect(jsonDecode(form['block_list']!), hasLength(2));
            expect(form['content-md5'], md5.convert(bytes).toString());
            return jsonResponse({
              'errno': 0,
              'uploadid': 'task',
              'return_type': 1,
              'block_list': [0, 1],
            });
          }
          if (r.uri.queryParameters['method'] == 'locateupload') {
            return jsonResponse({
              'error_code': 0,
              'servers': [
                {'server': 'https://upload.pcs.baidu.com'},
              ],
            });
          }
          if (r.body is HttpUpload) {
            expect(r.uri.host, 'upload.pcs.baidu.com');
            expect(r.uri.path, '/rest/2.0/pcs/superfile2');
            expect(r.uri.queryParameters['clienttype'], '1');
            final part = int.parse(r.uri.queryParameters['partseq']!);
            final received = await (r.body as HttpUpload)
                .open()
                .expand((b) => b)
                .toList();
            expect(
              received,
              bytes.sublist(
                part * 4 * 1024 * 1024,
                part == 0 ? 4 * 1024 * 1024 : bytes.length,
              ),
            );
            parts++;
            return jsonResponse({
              'md5': badHash ? '0' * 32 : md5.convert(received).toString(),
            });
          }
          if (r.uri.path == '/api/create') {
            commits++;
            expect(Uri.splitQueryString(r.body as String)['rtype'], '0');
            return jsonResponse({'errno': 0, 'fs_id': '99'});
          }
          expect(r.uri.path, '/api/list');
          return jsonResponse({
            'errno': 0,
            'list': [
              {
                'fs_id': '99',
                'path': '/folder/sample.txt',
                'server_filename': 'sample.txt',
                'isdir': 0,
                'size': bytes.length,
              },
            ],
          });
        });
        final connector = BaiduConnector(http),
            c = Credential('fixture', {'primary': 'BDUSS=fixture'});
        const session = BrowseSession(
          platform: CloudPlatform.baidu,
          mode: BrowseMode.personal,
          title: 'files',
          rootId: '/',
        );
        final request = connector.upload(session, '/folder', _source(bytes), c);
        if (badHash) {
          await expectLater(request, throwsA(isA<AppException>()));
          expect(commits, 0);
          // Other temporary blocks may already be in flight; none can merge
          // after a failed digest, regardless of completion order.
          expect(parts, inInclusiveRange(1, 2));
        } else {
          expect((await request).id, '99');
          expect(commits, 1);
          expect(parts, 2);
        }
      },
    );
  }
  for (final mode in ['resumable', 'instant', 'rejected']) {
    test('Xunlei GCID and upload flow match the protocol, mode=$mode', () async {
      final bytes = Uint8List.fromList(
        List.generate(262144 + 17, (i) => (i * 7) % 256),
      );
      final vault = Vault(StateStore.memory());
      final c = Credential('fixture', {
        'primary': 'fixture-access',
        'accessToken': 'fixture-access',
        'refreshToken': 'fixture-refresh',
        'deviceId': 'fixture-device',
        'clientId': XunleiProtocol.clientId,
        'clientSecret': 'fixture-client-secret',
        'captchaToken': 'fixture-captcha',
      }, updatedAt: 42);
      await vault.putCredential(CloudPlatform.xunlei, c);
      var uploads = 0, lists = 0;
      final http = FakeHttp((r) async {
        if (r.body is HttpUpload) {
          uploads++;
          expect(r.headers['Authorization'], startsWith('AWS4-HMAC-SHA256 '));
          expect(r.headers['Cookie'], isNull);
          expect(
            await (r.body as HttpUpload).open().expand((b) => b).toList(),
            bytes,
          );
          return HttpResult(mode == 'rejected' ? 403 : 200, '');
        }
        expect(r.uri.path, '/drive/v1/files');
        if (r.method == 'POST') {
          // Independent Python hashlib vector over the OpenList GCID block format.
          expect(r.json['hash'], 'B0B2EE87BE21864B5248596E8F69F89191D8706F');
          expect(r.json['kind'], 'drive#file');
          expect(r.json['upload_type'], 'UPLOAD_TYPE_RESUMABLE');
          return jsonResponse({
            'file': {'id': 'uploaded'},
            'upload_type': mode == 'instant'
                ? 'UPLOAD_TYPE_INSTANT'
                : 'UPLOAD_TYPE_RESUMABLE',
            if (mode != 'instant')
              'resumable': {
                'params': {
                  'endpoint': 'https://storage.example',
                  'bucket': 'bucket',
                  'key': 'object',
                  'access_key_id': 'temp-access',
                  'access_key_secret': 'temp-secret',
                  'security_token': 'temp-session',
                },
              },
          });
        }
        lists++;
        return jsonResponse({
          'files': [
            {
              'id': 'uploaded',
              'name': 'sample.txt',
              'kind': 'drive#file',
              'size': bytes.length,
              'phase': 'PHASE_TYPE_COMPLETE',
            },
          ],
        });
      });
      const session = BrowseSession(
        platform: CloudPlatform.xunlei,
        mode: BrowseMode.personal,
        title: 'files',
        rootId: '',
      );
      final request = XunleiConnector(
        http,
        vault,
        XunleiDevices(vault),
      ).upload(session, '', _source(bytes), c);
      if (mode == 'rejected') {
        await expectLater(request, throwsA(isA<AppException>()));
        expect(lists, 0);
      } else {
        expect((await request).id, 'uploaded');
        expect(lists, 1);
      }
      expect(uploads, mode == 'instant' ? 0 : 1);
    });
  }
}
