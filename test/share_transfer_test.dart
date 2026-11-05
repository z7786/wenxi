import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

class _TransferFixture {
  _TransferFixture(this.platform) {
    http = FakeHttp(respond);
    outbox = CleanupOutbox(store, http);
    repository = CloudRepository(http, vault, outbox);
    final original = repository.connector(platform);
    delegateStage = original is Pan123Connector
        ? original.stageCleanup!
        : (original as C139Connector).stageCleanup!;
    // Keep real connectors, with a zero-delay polling clock.
    repository.connectors[platform] = platform == CloudPlatform.pan123
        ? Pan123Connector(
            http,
            vault,
            taskDelay: Duration.zero,
            stageCleanup: stage,
          )
        : C139Connector(http, taskDelay: Duration.zero, stageCleanup: stage);
  }
  final CloudPlatform platform;
  final store = StateStore.memory();
  late final vault = Vault(store);
  late final FakeHttp http;
  late final CleanupOutbox outbox;
  late final CloudRepository repository;
  late final Future<void> Function(DownloadCleanup) delegateStage;
  final staged = <DownloadCleanup>[];
  bool failTransfer = false, mismatch = false, emptyFolder = false;
  bool failCommandDetails = false;
  bool directSave = false;
  int commandDetails = 0;
  int polls = 0;
  String folder = '', folderName = '';
  Future<void> stage(DownloadCleanup value) async {
    staged.add(value);
    await delegateStage(value);
  }

  Credential credential([int revision = 42]) => Credential(
    'fixture',
    platform == CloudPlatform.pan123
        ? {
            'primary': 'fixture-token',
            'accessToken': 'fixture-token',
            'authType': 'webToken',
          }
        : {
            'primary': 'skey=fixture; ud_id=domain',
            'authorization':
                'Basic ${base64Encode(utf8.encode('pc:13800000000:fixture'))}',
          },
    updatedAt: revision,
  );
  BrowseSession get share => shareWithId('link');
  BrowseSession shareWithId(String linkId, {bool command = false}) =>
      BrowseSession(
        platform: platform,
        mode: BrowseMode.share,
        title: 'share',
        rootId: 'share-root',
        metadata: {
          'shareKey': 'key',
          'passcode': 'a123',
          'linkId': linkId,
          if (command) 'linkCode': 'b9gaLFbe4PUz',
          'password': 'a123',
        },
      );
  CloudFile get file => CloudFile(
    id: platform == CloudPlatform.pan123 ? '42' : 'source-file',
    name: 'example.zip',
    size: 4,
    hashType: platform == CloudPlatform.pan123 ? 'md5' : null,
    hashValue: platform == CloudPlatform.pan123
        ? '0123456789abcdef0123456789abcdef'
        : null,
    token: encoded({
      's3': '123456-0',
      'etag': '0123456789abcdef0123456789abcdef',
      'storage': 'node',
    }),
  );
  HttpResult ok(Json data) => jsonResponse({
    'code': platform == CloudPlatform.pan123 ? 0 : '0000',
    'data': data,
  });
  HttpResult respond(RecordedRequest r) {
    final path = r.uri.path;
    if (path.endsWith('/getOutLinkGeneral')) {
      commandDetails++;
      expect(r.headers['Authorization'], credential().field('authorization'));
      final plain = C139Protocol.decrypt(r.body as String);
      final body = asJson(jsonDecode(plain)).obj('getOutLinkGeneralReq');
      expect(body, {
        'account': '13800000000',
        'linkCode': 'b9gaLFbe4PUz',
        'linkCodeType': 1,
        'passwd': 'a123',
        'isPasswd': 0,
      });
      return ok({
        'getOutLinkGeneralResp': {
          'outLinkGeneral': [
            {'linkID': failCommandDetails ? '' : 'resolved-command-share'},
          ],
        },
      });
    }
    if (path.endsWith('/upload_request') || path.endsWith('/file/create')) {
      folder = platform == CloudPlatform.pan123 ? '900' : 'temporary-folder';
      folderName = r.json.str(
        platform == CloudPlatform.pan123 ? 'fileName' : 'name',
      );
      expect(folderName, startsWith('AsterLink临时转存_'));
      expect(
        r.json['parentFileId'],
        platform == CloudPlatform.pan123 ? 0 : 'root',
      );
      expect(r.json['type'], platform == CloudPlatform.pan123 ? 1 : 'folder');
      if (platform == CloudPlatform.pan123) expect(r.json['duplicate'], 1);
      return ok(
        platform == CloudPlatform.pan123
            ? {
                'Info': {'FileId': 900},
              }
            : {'fileId': folder},
      );
    }
    if (path.endsWith('/copy/save')) {
      expect(staged, hasLength(1));
      expect(r.json.list('fileList').single['parentFileId'], 900);
      expect(r.json.list('fileList').single['fileId'], 42);
      expect(r.json['sharePwd'], 'a123');
      return ok({'taskID': 'transfer-task'});
    }
    if (path.endsWith('/copy/save/get')) {
      polls++;
      return ok({
        'state': failTransfer
            ? 'failed'
            : polls < 2
            ? 'running'
            : 'success',
      });
    }
    if (path.endsWith('/createOuterLinkBatchOprTask')) {
      expect(staged, hasLength(directSave ? 0 : 1));
      final body = asJson(jsonDecode(C139Protocol.decrypt(r.body as String)));
      final request = body.obj('createOuterLinkBatchOprTaskReq');
      expect(
        request.str('linkID'),
        commandDetails > 0 ? 'resolved-command-share' : 'link',
      );
      expect(request.obj('taskInfo').str('linkID'), request.str('linkID'));
      expect(
        body
            .obj('createOuterLinkBatchOprTaskReq')
            .obj('taskInfo')['newCatalogID'],
        directSave ? 'chosen-directory' : folder,
      );
      expect(
        body
            .obj('createOuterLinkBatchOprTaskReq')
            .obj('taskInfo')['contentInfoList'],
        ['/source-file'],
      );
      return ok({'taskID': 'transfer-task'});
    }
    if (path.endsWith('/queryBatchOprTaskDetail')) {
      polls++;
      return ok({
        'batchOprTask': {
          'taskStatus': failTransfer
              ? 3
              : polls < 2
              ? 1
              : 2,
          'progress': polls < 2 ? 10 : 100,
        },
        'contentList': {
          'idRspInfo': [
            {'srcId': 'source-file', 'rstId': 'saved-file', 'reason': '0'},
          ],
        },
      });
    }
    if (path.endsWith('/file/list/new')) {
      expect(polls, 2);
      expect(r.uri.queryParameters['parentFileId'], folder);
      return ok({
        'InfoList': emptyFolder
            ? []
            : [
                {
                  'FileId': 901,
                  'FileName': file.name,
                  'Size': mismatch ? 40 : 4,
                  'Type': 0,
                  'Etag': '0123456789abcdef0123456789abcdef',
                  'S3KeyFlag': '123456-1',
                },
              ],
        'Next': '-1',
      });
    }
    if (path.endsWith('/file/list')) {
      expect(polls, 2);
      expect(r.json['parentFileId'], folder);
      return ok({
        'items': emptyFolder
            ? []
            : [
                {
                  'fileId': 'saved-file',
                  'name': file.name,
                  'size': mismatch ? 40 : 4,
                  'type': 'file',
                },
              ],
      });
    }
    if (path.endsWith('/download_info')) {
      expect(r.json['fileId'], 901);
      expect(r.json.containsKey('ShareKey'), isFalse);
      return ok({
        'DownloadUrl': 'https://cdn.example/selected?signature=retained',
      });
    }
    if (path.endsWith('/getDownloadUrl')) {
      expect(r.json, {'fileId': 'saved-file'});
      return ok({
        'downloadUrl': 'https://cdn.example/selected?signature=retained',
      });
    }
    if (r.uri.host == 'cdn.example') return const HttpResult(200, '');
    if (path.endsWith('/file/trash')) {
      expect(r.json.list('fileTrashInfoList').single['FileId'], 900);
      expect(r.json.list('fileTrashInfoList').single['FileName'], folderName);
      return ok({});
    }
    if (path.endsWith('/recyclebin/batchTrash')) {
      expect(r.json['fileIds'], [folder]);
      return ok({'taskId': 'delete-task'});
    }
    if (path.endsWith('/task/get')) {
      return ok({
        'taskInfo': {'status': 'success', 'progress': 100},
        'batchFileResults': [],
      });
    }
    throw StateError('Unexpected request $path');
  }
}

void main() {
  test(
    'Mobile command save resolves its share ID and writes only to the chosen directory',
    () async {
      final fixture = _TransferFixture(CloudPlatform.c139)..directSave = true;
      final connector = fixture.repository.connector(CloudPlatform.c139);
      await connector.saveShare(
        fixture.shareWithId('', command: true),
        [fixture.file],
        'chosen-directory',
        fixture.credential(),
      );
      expect(fixture.commandDetails, 1);
      expect(fixture.polls, 2);
      expect(fixture.staged, isEmpty);
      expect(fixture.folder, isEmpty);
    },
  );

  test(
    'Mobile command from an old directory resolves its real share ID before download transfer',
    () async {
      final fixture = _TransferFixture(CloudPlatform.c139);
      await fixture.vault.putCredential(
        CloudPlatform.c139,
        fixture.credential(),
      );
      final spec = await fixture.repository.prepare(
        fixture.shareWithId('', command: true),
        fixture.file,
      );
      expect(fixture.commandDetails, 1);
      expect(fixture.polls, 2);
      expect(fixture.staged, hasLength(1));
      expect(spec.url, 'https://cdn.example/selected?signature=retained');
      expect(spec.cleanup, same(fixture.staged.single));
      expect(fixture.http.calls.first.uri.path, endsWith('/getOutLinkGeneral'));
    },
  );

  test(
    'Missing mobile command details never create a temporary folder or transfer',
    () async {
      final fixture = _TransferFixture(CloudPlatform.c139)
        ..failCommandDetails = true;
      await fixture.vault.putCredential(
        CloudPlatform.c139,
        fixture.credential(),
      );
      await expectLater(
        fixture.repository.prepare(
          fixture.shareWithId('', command: true),
          fixture.file,
        ),
        throwsA(isA<AppException>()),
      );
      expect(fixture.commandDetails, 1);
      expect(fixture.staged, isEmpty);
      expect(fixture.folder, isEmpty);
      expect(fixture.http.calls, hasLength(1));
    },
  );

  for (final platform in [CloudPlatform.pan123, CloudPlatform.c139]) {
    test(
      '${platform.key} transfers selected share file then fetches personal link and retains cleanup until release',
      () async {
        final fixture = _TransferFixture(platform);
        await fixture.vault.putCredential(platform, fixture.credential());
        final progress = OperationProgress();
        addTearDown(progress.dispose);
        final spec = await progress.run(
          () => fixture.repository.prepare(fixture.share, fixture.file),
        );
        expect(progress.value.map((step) => step.stage), [
          OperationStage.createTemporary,
          OperationStage.transfer,
          OperationStage.waitTransfer,
          OperationStage.downloadLink,
        ]);
        expect(
          progress.value.every(
            (step) => step.status == OperationStepStatus.completed,
          ),
          isTrue,
        );
        expect(spec.url, 'https://cdn.example/selected?signature=retained');
        expect(spec.expectedSize, 4);
        expect(spec.cleanup, same(fixture.staged.single));
        expect(spec.source!.obj('file').str('id'), fixture.file.id);
        await fixture.outbox.ready(spec.cleanup);
        await fixture.outbox.drain();
        expect(fixture.outbox.pendingCount, 1);
        expect(fixture.outbox.progress.value, isEmpty);
        await fixture.outbox.release(spec.cleanup);
        await fixture.outbox.ready(spec.cleanup);
        await fixture.outbox.drain();
        expect(fixture.outbox.pendingCount, 0);
        expect(
          fixture.outbox.progress.value.single.stage,
          OperationStage.cleanup,
        );
        expect(
          fixture.outbox.progress.value.single.status,
          OperationStepStatus.completed,
        );
        expect(
          fixture.http.calls.any(
            (r) =>
                r.uri.path.contains('/share/download/') ||
                r.uri.path.contains('/dlFromOutLink'),
          ),
          isFalse,
        );
      },
    );
    test(
      '${platform.key} failed transfer never requests file list or download URL',
      () async {
        final fixture = _TransferFixture(platform)..failTransfer = true;
        await fixture.vault.putCredential(platform, fixture.credential());
        final progress = OperationProgress();
        addTearDown(progress.dispose);
        await expectLater(
          progress.run(
            () => fixture.repository.prepare(fixture.share, fixture.file),
          ),
          throwsA(isA<AppException>()),
        );
        // The server rejects the transfer job before the destination is read.
        expect(progress.value.last.stage, OperationStage.transfer);
        expect(progress.value.last.status, OperationStepStatus.failed);
        expect(
          progress.value.any(
            (step) => step.stage == OperationStage.downloadLink,
          ),
          isFalse,
        );
        expect(
          fixture.http.calls.any(
            (r) =>
                r.uri.path.contains('/file/list') ||
                r.uri.path.contains('DownloadUrl') ||
                r.uri.path.contains('download_info'),
          ),
          isFalse,
        );
        expect(fixture.staged, hasLength(1));
        expect(
          asJson(
            fixture.store.data.obj('cleanups').values.single,
          ).boolean('ready'),
          isTrue,
        );
      },
    );
    test(
      '${platform.key} absent or mismatched transferred file never falls back to shared URL',
      () async {
        final fixture = _TransferFixture(platform)..mismatch = true;
        await fixture.vault.putCredential(platform, fixture.credential());
        await expectLater(
          fixture.repository.prepare(fixture.share, fixture.file),
          throwsA(isA<AppException>()),
        );
        expect(
          fixture.http.calls.any(
            (r) =>
                r.uri.path.contains('DownloadUrl') ||
                r.uri.path.contains('download_info'),
          ),
          isFalse,
        );
      },
    );
    test(
      '${platform.key} account switch defers temporary cleanup without touching new account',
      () async {
        final fixture = _TransferFixture(platform);
        await fixture.vault.putCredential(platform, fixture.credential());
        final spec = await fixture.repository.prepare(
          fixture.share,
          fixture.file,
        );
        await fixture.outbox.release(spec.cleanup);
        await fixture.outbox.ready(spec.cleanup);
        await fixture.vault.putCredential(platform, fixture.credential(99));
        final before = fixture.http.calls.length;
        await fixture.outbox.drain();
        expect(fixture.http.calls.length, before);
        expect(fixture.outbox.pendingCount, 1);
        await fixture.vault.putCredential(platform, fixture.credential());
        await fixture.outbox.drain();
        expect(fixture.outbox.pendingCount, 0);
      },
    );
  }
  test('Legacy cleanup keys survive the optional semantic action field', () {
    const cleanup = DownloadCleanup(
      url: 'https://example.com/delete',
      body: '{"id":"temporary"}',
    );
    final old = cleanup.toJson()..remove('action');
    expect(cleanup.toJson().containsKey('action'), isFalse);
    expect(cleanupKey(DownloadCleanup.fromJson(old)), cleanupKey(cleanup));
  });
}
