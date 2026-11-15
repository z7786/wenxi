import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/aliyun.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/providers/quark_uc.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/uploads/upload_io.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';
import 'token_cloud_support.dart';
import 'native_login_support.dart';

UploadFile _source(
  int size, {
  void Function()? onRead,
  String name = 'sample.bin',
}) => UploadFile(
  name: name,
  size: size,
  read: (start, end) async* {
    onRead?.call();
    for (var offset = start; offset < end; offset += 65536) {
      yield Uint8List((offset + 65536).clamp(offset, end) - offset);
    }
  },
);

void main() {
  for (final badPart in [false, true]) {
    test(
      'Tianyi concurrent parts verify signed hashes and merge only after success: badPart=$badPart',
      () async {
        final key = LoginTestKey();
        final release = Completer<void>(), second = Completer<void>();
        const size = 10 * 1024 * 1024 + 3;
        final zeroPart = Uint8List(10 * 1024 * 1024);
        final full = md5.convert(Uint8List(size)).toString();
        final hashes = [
          md5.convert(zeroPart).toString().toUpperCase(),
          md5.convert(Uint8List(3)).toString().toUpperCase(),
        ];
        final slice = md5.convert(utf8.encode(hashes.join('\n'))).toString();
        var reads = 0, merges = 0;
        final http = FakeHttp((request) async {
          if (request.uri.path == '/api/portal/v2/getUserBriefInfo.action') {
            return jsonResponse({'res_code': 0, 'sessionKey': 'session'});
          }
          if (request.uri.path == '/api/security/generateRsaKey.action') {
            return jsonResponse({
              'res_code': 0,
              'pubKey': key.spki,
              'pkId': 'public-key',
            });
          }
          if (request.uri.host == 'upload.cloud.189.cn') {
            final secret = key.decrypt(request.headers['EncryptionText']!);
            final encrypted = request.uri.queryParameters['params']!;
            final expected = Hmac(sha1, utf8.encode(secret))
                .convert(
                  utf8.encode(
                    'SessionKey=session&Operate=GET&RequestURI=${request.uri.path}&Date=${request.headers['X-Request-Date']}&params=$encrypted',
                  ),
                )
                .toString();
            expect(request.headers['Signature'], expected);
            final cipher =
                pc.PaddedBlockCipherImpl(
                  pc.PKCS7Padding(),
                  pc.ECBBlockCipher(pc.AESEngine()),
                )..init(
                  false,
                  pc.PaddedBlockCipherParameters<pc.KeyParameter, Null>(
                    pc.KeyParameter(
                      Uint8List.fromList(utf8.encode(secret.substring(0, 16))),
                    ),
                    null,
                  ),
                );
            final plain = utf8.decode(
              cipher.process(
                Uint8List.fromList([
                  for (var i = 0; i < encrypted.length; i += 2)
                    int.parse(encrypted.substring(i, i + 2), radix: 16),
                ]),
              ),
            );
            // The encrypted parameter block is not a URL form. A Base64 MD5
            // contains literal '+' characters which must not become spaces.
            final params = <String, String>{
              for (final pair in plain.split('&'))
                pair.substring(0, pair.indexOf('=')): pair.substring(
                  pair.indexOf('=') + 1,
                ),
            };
            if (request.uri.path == '/person/initMultiUpload') {
              expect(params['fileMd5'], full);
              expect(params['sliceMd5'], slice);
              return jsonResponse({
                'code': 'SUCCESS',
                'data': {'uploadFileId': 'upload', 'fileDataExists': 0},
              });
            }
            if (request.uri.path == '/person/getMultiUploadUrls') {
              final info = params['partInfo']!,
                  part = int.parse(info.split('-').first);
              expect(
                info.substring(info.indexOf('-') + 1),
                base64Encode([
                  for (var i = 0; i < 32; i += 2)
                    int.parse(hashes[part - 1].substring(i, i + 2), radix: 16),
                ]),
              );
              return jsonResponse({
                'code': 'SUCCESS',
                'uploadUrls': {
                  'partNumber_$part': {
                    'requestURL': 'https://payload.example/$part',
                    'requestHeader': '',
                  },
                },
              });
            }
            expect(request.uri.path, '/person/commitMultiUploadFile');
            merges++;
            expect(params['fileMd5'], full);
            expect(params['sliceMd5'], slice);
            return jsonResponse({
              'code': 'SUCCESS',
              'data': {
                'fileId': '42',
                'fileName': 'sample.bin',
                'fileSize': size,
                'parentFolderId': '0',
                'md5': full,
              },
            });
          }
          final upload = request.body as HttpUpload;
          if (request.uri.path == '/1') {
            await RequestScope.cancellable(release.future);
          } else {
            second.complete();
            if (badPart) {
              throw const HttpRequestFailure(
                'failed part',
                kind: 'receiveTimeout',
              );
            }
          }
          await upload.open().drain<void>();
          return const HttpResult(200, '');
        });
        final write = WriteRequestScope();
        final uploading = write.run(
          () => TianyiConnector(RetryingJsonHttp(http)).upload(
            const BrowseSession(
              platform: CloudPlatform.tianyi,
              mode: BrowseMode.personal,
              title: 'Files',
              rootId: '0',
            ),
            '0',
            _source(size, onRead: () => reads++),
            Credential('fixture', {'primary': 'COOKIE_LOGIN_USER=fixture'}),
          ),
        );
        if (badPart) {
          await expectLater(uploading, throwsA(isA<HttpRequestFailure>()));
          expect(write.mayHaveWritten, isFalse);
          expect(merges, 0);
        } else {
          await second.future;
          expect(merges, 0);
          release.complete();
          expect((await uploading).id, '42');
          expect(
            reads,
            3,
          ); // One whole/slice digest pass plus two payload reads.
          expect(merges, 1);
          expect(
            http.calls.any((r) => r.uri.path.endsWith('listFiles.action')),
            isFalse,
          );
        }
      },
    );
  }
  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    test(
      '$platform uploads parts concurrently and merges ETags in part order',
      () async {
        final release = Completer<void>(), second = Completer<void>();
        var reads = 0, merged = false;
        final progress = <UploadProgress>[];
        final http = FakeHttp((request) async {
          if (request.uri.path.endsWith('file/upload/pre')) {
            return jsonResponse({
              'status': 200,
              'metadata': {'part_size': 4},
              'data': {
                'task_id': 'upload-task',
                'bucket': 'bucket',
                'obj_key': 'key',
                'upload_id': 'upload-id',
                'upload_url': 'https://oss.example',
                'auth_info': 'fixture',
                'callback': {'callbackUrl': 'https://callback.example'},
              },
            });
          }
          if (request.uri.path.endsWith('file/update/hash')) {
            final bytes = Uint8List(12);
            expect(request.json['md5'], md5.convert(bytes).toString());
            expect(request.json['sha1'], sha1.convert(bytes).toString());
            return jsonResponse({
              'status': 200,
              'data': {'finish': false},
            });
          }
          if (request.uri.path.endsWith('file/upload/auth')) {
            return jsonResponse({
              'status': 200,
              'data': {'auth_key': 'fixture'},
            });
          }
          if (request.body is HttpUpload) {
            final part = int.parse(request.uri.queryParameters['partNumber']!);
            final upload = request.body as HttpUpload;
            if (part == 1) {
              upload.onProgress!(1, 4);
              await release.future;
            } else {
              upload.onProgress!(4, 4);
              if (part == 2) second.complete();
            }
            await upload.open().drain<void>();
            return HttpResult(200, '', {
              'etag': ['"part-$part"'],
            });
          }
          if (request.uri.host == 'bucket.oss.example') {
            expect(merged, isFalse);
            merged = true;
            expect(
              request.body,
              UploadIO.completeXml(['"part-1"', '"part-2"', '"part-3"']),
            );
            return const HttpResult(200, '{}');
          }
          if (request.uri.path.endsWith('file/upload/finish')) {
            expect(merged, isTrue);
            return jsonResponse({'status': 200, 'data': {}});
          }
          expect(request.uri.path, endsWith('file/sort'));
          return jsonResponse({
            'status': 200,
            'data': {
              'list': [
                {
                  'fid': 'saved',
                  'file_name': 'sample.bin',
                  'size': 12,
                  'pdir_fid': '0',
                  'dir': false,
                },
              ],
            },
          });
        });
        final uploading = QuarkUcConnector(platform, http).upload(
          BrowseSession(
            platform: platform,
            mode: BrowseMode.personal,
            title: 'Files',
            rootId: '0',
          ),
          '0',
          _source(12, onRead: () => reads++),
          Credential('fixture', {'primary': 'cookie=fixture'}),
          onProgress: progress.add,
        );
        await Future.any([second.future, uploading.then((_) {})]);
        await until(
          () => progress.any(
            (p) => p.phase == UploadPhase.uploading && p.sent >= 9,
          ),
        );
        expect(progress.last.sent, 9);
        expect(merged, isFalse);
        release.complete();
        expect((await uploading).id, 'saved');
        expect(reads, 4); // One combined digest read, three payload ranges.
        expect(http.calls.where((r) => r.body is HttpUpload), hasLength(3));
      },
    );
  }

  test(
    'Aliyun sends two ranges together and confirms a completed receipt without listing',
    () async {
      final vault = await tokenVault(CloudPlatform.aliyun);
      final release = Completer<void>(), second = Completer<void>();
      var active = 0, maxActive = 0;
      const size = 10 * 1024 * 1024 + 7;
      final http = FakeHttp((request) async {
        if (request.uri.path == '/adrive/v2/file/createWithFolders') {
          return jsonResponse({
            'file_id': 'saved',
            'upload_id': 'upload',
            'part_info_list': [
              {'part_number': 1, 'upload_url': 'https://upload.example/1'},
              {'part_number': 2, 'upload_url': 'https://upload.example/2'},
            ],
          });
        }
        if (request.body is HttpUpload) {
          active++;
          if (active > maxActive) maxActive = active;
          try {
            if (request.uri.path == '/1') {
              await release.future;
            } else {
              second.complete();
            }
            await (request.body as HttpUpload).open().drain<void>();
            return const HttpResult(200, '');
          } finally {
            active--;
          }
        }
        if (request.uri.path == '/v2/file/complete') {
          expect(active, 0);
          return jsonResponse({
            ...aliFile('saved', name: 'sample.bin'),
            'size': size,
            'status': 'available',
          });
        }
        return aliDefaultResponse(request);
      });
      final uploading = AliyunConnector(http, vault, now: () => tokenClock)
          .upload(
            tokenPersonal(CloudPlatform.aliyun),
            'root',
            _source(size),
            vault.credential(CloudPlatform.aliyun)!,
          );
      await second.future;
      expect(maxActive, 2);
      expect(http.calls.any((r) => r.uri.path == '/v2/file/complete'), isFalse);
      release.complete();
      expect((await uploading).size, size);
      expect(
        http.calls.any((r) => r.uri.path == '/adrive/v3/file/list'),
        isFalse,
      );
    },
  );

  test(
    'Baidu full save receipt avoids listing and combined hashes read the file once',
    () async {
      var reads = 0;
      final bytes = Uint8List.fromList([1, 2, 3]);
      final http = FakeHttp((request) async {
        if (request.uri.path == '/api/precreate') {
          final params = Uri.splitQueryString(request.body as String);
          expect(params['content-md5'], md5.convert(bytes).toString());
          expect(params['slice-md5'], md5.convert(bytes).toString());
          return jsonResponse({
            'errno': 0,
            'return_type': 2,
            'info': {
              'fs_id': '42',
              'server_filename': 'sample.bin',
              'size': 3,
              'isdir': 0,
              'path': '/sample.bin',
            },
          });
        }
        throw StateError('Unexpected directory fetch: ${request.uri.path}');
      });
      final file = UploadFile(
        name: 'sample.bin',
        size: bytes.length,
        read: (start, end) async* {
          reads++;
          yield Uint8List.sublistView(bytes, start, end);
        },
      );
      final result = await BaiduConnector(http).upload(
        const BrowseSession(
          platform: CloudPlatform.baidu,
          mode: BrowseMode.personal,
          title: 'Files',
          rootId: '/',
        ),
        '/',
        file,
        Credential('fixture', {'primary': 'BDUSS=fixture'}),
      );
      expect(result.id, '42');
      expect(result.token, '/sample.bin');
      expect(reads, 1);
      expect(http.calls, hasLength(1));
    },
  );

  for (final bad in ['id', 'name', 'size', 'directory', 'hash']) {
    test(
      'completed receipt rejects a mismatched $bad and retains its accepted ID',
      () async {
        final saved = <String>[];
        final scope = WriteRequestScope(
          onAcceptedId: (id) async => saved.add(id),
        );
        final file = _source(3);
        final receipt = CloudFile(
          id: bad == 'id' ? 'other' : '42',
          name: bad == 'name' ? 'wrong.bin' : file.name,
          size: bad == 'size' ? 4 : 3,
          isDirectory: bad == 'directory',
          hashType: bad == 'hash' ? 'md5' : null,
          hashValue: bad == 'hash' ? 'f' * 32 : null,
        );
        final io = UploadIO(FakeHttp(), file, null);
        await io.digest(md5);
        await expectLater(
          scope.run(
            () => io.confirm(
              () async => throw StateError('Must not list'),
              id: '42',
              receipt: receipt,
            ),
          ),
          throwsA(isA<AppException>()),
        );
        expect(saved, ['42']);
        expect(scope.mayHaveWritten, isTrue);
      },
    );
  }

  test(
    'lost parallel OSS merge is sent once and keeps save uncertainty',
    () async {
      var merges = 0;
      final http = FakeHttp((request) async {
        if (request.uri.queryParameters.containsKey('uploads')) {
          return const HttpResult(200, '<UploadId>upload</UploadId>');
        }
        if (request.body is HttpUpload) {
          await (request.body as HttpUpload).open().drain<void>();
          return HttpResult(200, '', {
            'etag': ['part-${request.uri.queryParameters['partNumber']}'],
          });
        }
        if (request.method == 'DELETE') return const HttpResult(204, '');
        merges++;
        expect(request.body, UploadIO.completeXml(['part-1', 'part-2']));
        throw const HttpRequestFailure(
          'merge response lost',
          kind: 'receiveTimeout',
        );
      });
      final write = WriteRequestScope();
      final io = UploadIO(
        RetryingJsonHttp(http),
        _source(8 * 1024 * 1024 + 3),
        null,
      );
      await expectLater(
        write.run(
          () => io.oss(
            endpoint: 'https://oss.example',
            bucket: 'bucket',
            object: 'file',
            access: 'fixture',
            secret: 'fixture',
          ),
        ),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(merges, 1);
      expect(write.mayHaveWritten, isTrue);
      expect(http.calls.last.method, 'DELETE');
    },
  );
}
