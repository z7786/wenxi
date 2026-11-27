import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/upload/upload_manager.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'support.dart';

const _session = BrowseSession(
  platform: CloudPlatform.pan123,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '0',
);
final _credential = Credential('fixture', {
  'authType': 'webToken',
  'primary': 'test-token',
});
const _base = '/b/api/file/';
HttpResult _ok(Json data) => jsonResponse({'code': 0, 'data': data});
const _network = HttpRequestFailure(
  'response lost',
  kind: 'receiveTimeout',
  retryable: true,
);

class _Upload {
  _Upload({this.size = 3}) {
    bytes = Uint8List.fromList(List.generate(size, (i) => i % 251));
    hash = md5.convert(bytes).toString();
    source = UploadFile(
      name: 'sample.bin',
      size: size,
      read: (start, end) =>
          Stream.value(Uint8List.sublistView(bytes, start, end)),
    );
    http = FakeHttp(_respond);
    connector = Pan123Connector(
      http,
      Vault(store),
      listDelay: Duration.zero,
      now: () => clock,
      uploadWait: (d) async {
        waits.add(d);
        clock = clock.add(expire ? const Duration(minutes: 16) : d);
        onWait?.call();
      },
    );
  }
  final int size;
  final store = StateStore.memory();
  late final Uint8List bytes;
  late final String hash;
  late final UploadFile source;
  late final FakeHttp http;
  late final Pan123Connector connector;
  bool reuse = false, expire = false;
  DateTime clock = DateTime(2026, 10, 14);
  int sends = 0, commits = 0, polls = 0, lists = 0;
  final waits = <Duration>[];
  final sent = <int>[];
  void Function()? onWait;
  FutureOr<HttpResult> Function()? complete, poll, list;
  FutureOr<HttpResult> Function(RecordedRequest)? authorize, payload;
  Json get info => {
    'FileId': 42,
    'ParentFileId': 0,
    'FileName': source.name,
    'Size': size,
    'Type': 0,
    'Etag': hash,
    'S3KeyFlag': 'node-key',
    'StorageNode': 'node',
  };
  Future<HttpResult> _respond(RecordedRequest r) async {
    if (r.uri.path == '${_base}upload_request') {
      expect(r.json['etag'], hash);
      expect(r.json['size'], size);
      return _ok({
        'FileId': reuse ? 777 : 42,
        'Reuse': reuse,
        if (reuse) 'Info': info,
        'Key': 'object',
        'Bucket': 'bucket',
        'StorageNode': 'node',
        'UploadId': 'same-upload',
      });
    }
    if (r.uri.path == '${_base}s3_upload_object/auth' ||
        r.uri.path == '${_base}s3_repare_upload_parts_batch') {
      final part = r.json.integer('partNumberStart');
      expect(r.json['partNumberEnd'], part + 1);
      if (authorize != null) return await authorize!(r);
      return _ok({
        'presignedUrls': {'$part': 'https://upload.example/$part'},
      });
    }
    if (r.uri.host == 'upload.example') {
      sends++;
      expect(r.method, 'PUT');
      if (payload != null) return await payload!(r);
      sent.addAll(
        await (r.body as HttpUpload).open().expand((c) => c).toList(),
      );
      return const HttpResult(200, '');
    }
    if (r.uri.path == '${_base}upload_complete/v2') {
      commits++;
      expect(sent, bytes);
      expect(r.json['fileId'], '42');
      expect(r.json['fileSize'], size);
      expect(r.json['isMultipart'], size > 16 * 1024 * 1024);
      return complete == null ? _ok({'file_info': info}) : await complete!();
    }
    if (r.uri.path == '${_base}upload_complete/result') {
      polls++;
      expect(r.method, 'GET');
      expect(r.uri.queryParameters['fileId'], '42');
      expect(r.uri.queryParameters['uploadId'], 'same-upload');
      expect(r.uri.queryParameters['key'], 'object');
      expect(r.uri.queryParameters['fileSize'], '$size');
      return poll == null ? _ok({'file_info': info}) : await poll!();
    }
    if (r.uri.path == '${_base}list/new') {
      lists++;
      if (list != null) return await list!();
      throw _network;
    }
    throw StateError('Unexpected request: ${r.uri.path}');
  }

  Future<CloudFile> run() =>
      connector.upload(_session, '0', source, _credential);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'expired',
    'network',
    'authorization',
    'persistent',
    'cancel',
  ]) {
    test(
      '123 recovers the same part with renewed authorization: $mode',
      () async {
        final f = _Upload();
        addTearDown(f.store.dispose);
        final scope = RequestScope();
        var grants = 0;
        final bodies = <List<int>>[];
        f.authorize = (r) {
          grants++;
          expect(r.json['uploadId'], 'same-upload');
          expect(r.json['partNumberStart'], 1);
          if (mode == 'authorization' && grants == 1) throw _network;
          return _ok({
            'presignedUrls': {'1': 'https://upload.example/1?grant=$grants'},
          });
        };
        f.payload = (r) async {
          expect(r.uri.queryParameters['grant'], '$grants');
          final bytes = await (r.body as HttpUpload)
              .open()
              .expand((b) => b)
              .toList();
          bodies.add(bytes);
          if (mode == 'cancel') scope.cancel();
          if (mode == 'persistent' ||
              mode == 'cancel' ||
              (mode == 'expired' && f.sends == 1)) {
            return const HttpResult(
              403,
              '<Error><Code>AccessDenied</Code></Error>',
            );
          }
          if (mode == 'network' && f.sends == 1) throw _network;
          f.sent.addAll(bytes);
          return const HttpResult(200, '');
        };
        if (mode == 'persistent' || mode == 'cancel') {
          await expectLater(scope.run(f.run), throwsA(isA<AppException>()));
          expect(grants, mode == 'persistent' ? 3 : 1);
          expect(f.commits, 0);
        } else {
          expect((await scope.run(f.run)).id, '42');
          expect(grants, 2);
          expect(f.commits, 1);
        }
        for (final bytes in bodies) {
          expect(bytes, f.bytes);
        }
        expect(
          f.http.calls.where((r) => r.uri.path == '${_base}upload_request'),
          hasLength(1),
        );
      },
    );
  }
  for (final asynchronous in [false, true]) {
    test(
      '123 upload manager remains completed when final directory read fails: $asynchronous',
      () async {
        final f = _Upload();
        final vault = Vault(f.store);
        await vault.putCredential(CloudPlatform.pan123, _credential);
        final cloud = CloudRepository(
          f.http,
          vault,
          CleanupOutbox(f.store, f.http),
        );
        cloud.connectors[CloudPlatform.pan123] = f.connector;
        final manager = UploadManager(store: f.store, cloud: cloud);
        final directory = await Directory.systemTemp.createTemp(
          'pan123-upload-test-',
        );
        final file = File(p.join(directory.path, 'sample.bin'));
        addTearDown(() async {
          await manager.close();
          manager.dispose();
          if (await file.exists()) await file.delete();
          await directory.delete();
          f.store.dispose();
        });
        await file.writeAsBytes(f.bytes);
        f.list = () {
          if (f.commits > 0) throw _network;
          return _ok({'InfoList': [], 'Next': '-1'});
        };
        if (asynchronous) {
          f.complete = () => _ok({'async': true});
          f.poll = () =>
              f.polls < 2 ? _ok({'duration': 2}) : _ok({'file_info': f.info});
        }
        await manager.initialize();
        final ids = await manager.enqueue(
          cloud.bindSession(_session),
          '0',
          'files',
          [XFile(file.path)],
        );
        await until(() => !manager.task(ids.single)!.active);
        final task = manager.task(ids.single)!;
        expect(task.status, UploadStatus.completed);
        expect(task.error, isEmpty);
        expect(f.lists, 1); // Only the duplicate-name check before uploading.
        expect(f.commits, 1);
      },
    );
  }
  for (final size in [0, 3, 16 * 1024 * 1024 + 7]) {
    test(
      '123 completed upload succeeds even when directory refresh fails: $size',
      () async {
        final f = _Upload(size: size);
        addTearDown(f.store.dispose);
        final result = await f.run();
        expect(result.id, '42');
        expect(result.size, size);
        expect(result.hashValue, f.hash);
        expect(f.sends, size > 16 * 1024 * 1024 ? 2 : 1);
        expect(f.commits, 1);
        expect(f.polls, 0);
        expect(f.lists, 0);
      },
    );
  }
  test(
    '123 reused file uses Info identity and does not upload or refresh',
    () async {
      final f = _Upload()..reuse = true;
      addTearDown(f.store.dispose);
      expect((await f.run()).id, '42');
      expect(f.sends + f.commits + f.polls + f.lists, 0);
    },
  );
  test(
    '123 async merge polls official result until the file is committed',
    () async {
      final f = _Upload();
      addTearDown(f.store.dispose);
      f.complete = () => _ok({'async': true});
      f.poll = () =>
          f.polls < 3 ? _ok({'duration': 3}) : _ok({'file_info': f.info});
      expect((await f.run()).size, 3);
      expect(f.polls, 3);
      expect(f.waits, [const Duration(seconds: 3), const Duration(seconds: 3)]);
      expect(f.commits, 1);
      expect(f.sends, 1);
      expect(f.lists, 0);
    },
  );
  test(
    '123 lost merge response and transient poll failure do not reupload',
    () async {
      final f = _Upload();
      addTearDown(f.store.dispose);
      f.complete = () => throw _network;
      f.poll = () {
        if (f.polls < 3) throw _network;
        return _ok({'file_info': f.info});
      };
      expect((await f.run()).id, '42');
      expect(f.polls, 3);
      expect(f.commits, 1);
      expect(f.sends, 1);
      expect(f.lists, 0);
    },
  );
  test('123 explicit commit rejection is not marked as complete', () async {
    final f = _Upload();
    addTearDown(f.store.dispose);
    f.complete = () => jsonResponse({'code': 7, 'message': 'merge rejected'});
    await expectLater(f.run(), throwsA(isA<AppException>()));
    expect(f.polls, 0);
  });
  test(
    '123 HTTP 503 while acknowledging merge recovers the committed upload',
    () async {
      final f = _Upload();
      addTearDown(f.store.dispose);
      f.complete = () => const HttpResult(503, '<html>unavailable</html>');
      expect((await f.run()).id, '42');
      expect(f.commits, 1);
      expect(f.polls, 1);
    },
  );
  for (final field in ['Size', 'Etag', 'ParentFileId', 'Type']) {
    test('123 validates $field in successful upload receipt', () async {
      final f = _Upload();
      addTearDown(f.store.dispose);
      f.complete = () => _ok({
        'file_info': {...f.info, field: field == 'Etag' ? 'wrong-hash' : 900},
      });
      await expectLater(f.run(), throwsA(isA<AppException>()));
      expect(f.lists, 0);
    });
  }
  test(
    '123 cancellation stops merge polling without confirming success',
    () async {
      final f = _Upload();
      final scope = RequestScope();
      addTearDown(f.store.dispose);
      f.complete = () => _ok({});
      f.poll = () => _ok({'duration': 2});
      f.onWait = scope.cancel;
      await expectLater(
        scope.run(f.run),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('取消'),
          ),
        ),
      );
      expect(f.polls, 1);
      expect(f.lists, 0);
    },
  );
  for (final visible in [true, false]) {
    test(
      '123 unavailable merge result recovers only a verified file: $visible',
      () async {
        final f = _Upload();
        addTearDown(f.store.dispose);
        f.complete = () => _ok({});
        f.poll = () => throw _network;
        f.list = () => _ok({
          'InfoList': [if (visible) f.info],
          'Next': '-1',
        });
        if (visible) {
          expect((await f.run()).hashValue, f.hash);
        } else {
          await expectLater(
            f.run(),
            throwsA(
              isA<AppException>().having(
                (e) => e.message,
                'message',
                contains('避免重复上传'),
              ),
            ),
          );
        }
        expect(f.polls, 4);
        expect(f.commits, 1);
        expect(f.lists, 1);
      },
    );
  }
  test(
    '123 pending merge has a finite wait and never invents completion',
    () async {
      final f = _Upload()..expire = true;
      addTearDown(f.store.dispose);
      f.complete = () => _ok({});
      f.poll = () => _ok({'duration': 2});
      await expectLater(
        f.run(),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('暂未确认'),
          ),
        ),
      );
      expect(f.polls, 1);
      expect(f.commits, 1);
    },
  );
}
