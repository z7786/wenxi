import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/transfer/rapid_transfer_task.dart';
import 'package:asterlink/ui/download_progress.dart';

const _session = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: '0',
);

RapidTransferEntry _entry(String id, int size) => RapidTransferEntry(
  CloudFile(id: id, name: '$id.bin', size: size),
  [],
  method: CrossTransferMethod.relay,
);

RapidTransferTask _task(List<RapidTransferEntry> entries) => RapidTransferTask(
  id: 'fixture',
  source: _session,
  target: _session,
  parent: '0',
  folderName: 'root',
  selections: entries.map((e) => e.file).toList(),
  createdAt: 1,
  scanned: true,
  status: RapidTaskStatus.running,
  entries: entries,
);

void main() {
  test('Overall progress weights a large file by bytes, not file count', () {
    final small = _entry('small', 1)..status = RapidEntryStatus.uploaded;
    final large = _entry('large', 999)
      ..status = RapidEntryStatus.downloading
      ..downloaded = 100;
    final task = _task([small, large]);
    expect(task.progress, closeTo(.051, 1e-9));
    expect(task.succeeded, 1);
    large
      ..status = RapidEntryStatus.uploading
      ..uploadPhase = UploadPhase.uploading
      ..payloadReady = true
      ..downloaded = 999
      ..sent = 100;
    expect(task.progress, closeTo(.5505, 1e-9));
  });

  test('Failure and queued retry preserve actual relay bytes', () {
    final entry = _entry('partial', 100)
      ..status = RapidEntryStatus.downloading
      ..downloaded = 40;
    expect(entry.progress, .2);
    entry.status = RapidEntryStatus.failed;
    expect(entry.progress, .2);
    entry.status = RapidEntryStatus.pending;
    expect(entry.progress, .2);
    entry
      ..status = RapidEntryStatus.failed
      ..payloadReady = true
      ..downloaded = 100
      ..sent = 30;
    expect(entry.progress, .65);
    final task = _task([entry])..status = RapidTaskStatus.completed;
    expect(task.progress, .65);
    expect(task.done, 1);
    expect(task.succeeded, 0);
    expect(task.canRetry, isTrue);
    expect(TransferProgress.cross(task).progress, .65);
    expect(TransferProgress.cross(task).status, TransferProgressStatus.failed);
  });

  test('Failed matches and skipped names are not transferred files', () {
    final failed = _entry('failed', 900)
      ..method = CrossTransferMethod.automatic
      ..status = RapidEntryStatus.failed;
    final good = _entry('good', 100)..status = RapidEntryStatus.reused;
    final skipped = _entry('skipped', 2000)
      ..status = RapidEntryStatus.duplicate;
    expect(failed.progress, 0);
    expect(skipped.progress, 0);
    final task = _task([failed, good, skipped]);
    expect(task.progress, .1);
    expect(task.succeeded, 1);
    expect(TransferProgress.crossPhase(task, upload: false).total, 900);
    expect(TransferProgress.crossPhase(task, upload: true).total, 900);
  });

  test('Pending files are included before their relay starts', () {
    final small = _entry('small', 100)..status = RapidEntryStatus.uploaded;
    final large = _entry('large', 900)..method = CrossTransferMethod.automatic;
    final task = _task([small, large]);
    for (final upload in [false, true]) {
      final initial = TransferProgress.crossPhase(task, upload: upload);
      expect(initial.total, 1000);
      expect(initial.transferred, 100);
      expect(initial.progress, .1);
      expect(initial.status, isNot(TransferProgressStatus.completed));
      large.method = CrossTransferMethod.relay;
      expect(TransferProgress.crossPhase(task, upload: upload).progress, .1);
    }
  });

  test('Failed file details do not look queued while other files run', () {
    final failed = _entry('failed', 100)
      ..status = RapidEntryStatus.failed
      ..downloaded = 100
      ..payloadReady = true
      ..sent = 25;
    final downloading = _entry('running', 900)
      ..status = RapidEntryStatus.downloading;
    final task = _task([failed, downloading]);
    expect(
      TransferProgress.crossPhase(task, upload: false).status,
      TransferProgressStatus.running,
    );
    expect(
      TransferProgress.crossPhase(
        task,
        upload: false,
        entries: [failed],
      ).status,
      TransferProgressStatus.completed,
    );
    final upload = TransferProgress.crossPhase(
      task,
      upload: true,
      entries: [failed],
    );
    expect(upload.status, TransferProgressStatus.failed);
    expect(upload.progress, .25);
    task.status = RapidTaskStatus.cancelled;
    expect(
      TransferProgress.crossPhase(task, upload: true, entries: [failed]).status,
      TransferProgressStatus.paused,
    );
  });

  test('All skipped batch does not claim transferred files', () {
    final skipped = _entry('duplicate', 100)
      ..status = RapidEntryStatus.duplicate;
    final task = _task([skipped])..status = RapidTaskStatus.completed;
    expect(task.succeeded, 0);
    expect(task.progress, 0);
    expect(task.stage, '全部已跳过');
    expect(task.canRetry, isFalse);
  });

  test('Download, upload preparation and confirmation are distinct', () {
    final entry = _entry('file', 100)
      ..status = RapidEntryStatus.downloading
      ..downloaded = 100
      ..downloadVerifying = true;
    final task = _task([entry]);
    final verifying = TransferProgress.crossPhase(task, upload: false);
    expect(verifying.status, TransferProgressStatus.processing);
    expect(verifying.processingLabel, '校验中');
    expect(verifying.progress, .99);
    entry
      ..downloadVerifying = false
      ..payloadReady = true
      ..status = RapidEntryStatus.uploading
      ..uploadPhase = UploadPhase.preparing;
    expect(
      TransferProgress.crossPhase(task, upload: false).status,
      TransferProgressStatus.completed,
    );
    final preparing = TransferProgress.crossPhase(task, upload: true);
    expect(preparing.status, TransferProgressStatus.processing);
    expect(preparing.processingLabel, '准备中');
    expect(preparing.progress, 0);
    entry
      ..uploadPhase = UploadPhase.finishing
      ..sent = 100;
    final confirming = TransferProgress.crossPhase(task, upload: true);
    expect(confirming.status, TransferProgressStatus.processing);
    expect(confirming.processingLabel, '确认中');
    expect(confirming.progress, .99);
    expect(confirming.transferred, 100);
    expect(task.stage, '正在确认 1 个');
    expect(task.progress, .99);
    entry.status = RapidEntryStatus.uploaded;
    expect(task.progress, 1);
    expect(TransferProgress.crossPhase(task, upload: true).progress, 1);
  });

  test(
    'Reconciling a restored write shows confirmation without new traffic',
    () {
      final entry = _entry('recover', 100)
        ..status = RapidEntryStatus.processing
        ..confirmationPending = true
        ..checkingTarget = true
        ..payloadReady = true
        ..downloaded = 100
        ..sent = 100;
      final task = _task([entry]);
      expect(task.stage, '正在确认 1 个');
      expect(TransferProgress.cross(task).processingLabel, '确认中');
      final upload = TransferProgress.crossPhase(task, upload: true);
      expect(upload.status, TransferProgressStatus.processing);
      expect(upload.processingLabel, '确认中');
      expect(upload.speed, 0);
      expect(upload.progress, .99);
      expect(TransferProgress.crossPhase(task, upload: false).progress, 1);
    },
  );

  test('Parallel phases and file detail use their own speeds', () {
    final download = _entry('down', 100)
      ..status = RapidEntryStatus.downloading
      ..downloaded = 50
      ..downloadSpeed = 200;
    final upload = _entry('up', 100)
      ..status = RapidEntryStatus.uploading
      ..uploadPhase = UploadPhase.uploading
      ..payloadReady = true
      ..sent = 50
      ..uploadSpeed = 25;
    final task = _task([download, upload])
      ..speed = 225
      ..downloadSpeed = 200
      ..uploadSpeed = 25;
    expect(TransferProgress.crossPhase(task, upload: false).speed, 200);
    expect(TransferProgress.crossPhase(task, upload: true).speed, 25);
    expect(
      TransferProgress.crossPhase(task, upload: true, entries: [upload]).speed,
      25,
    );
    expect(
      TransferProgress.crossPhase(task, upload: false, entries: [upload]).speed,
      0,
    );
    task.status = RapidTaskStatus.cancelled;
    expect(
      TransferProgress.crossPhase(task, upload: true).status,
      TransferProgressStatus.paused,
    );
  });

  test('Unknown sizes do not invent percentages', () {
    final known = _entry('known', 100)..status = RapidEntryStatus.uploaded;
    final unknown = _entry('unknown', 0)
      ..status = RapidEntryStatus.downloading
      ..downloaded = 20;
    final task = _task([known, unknown]);
    expect(task.progress, isNull);
    expect(TransferProgress.crossPhase(task, upload: false).total, 0);
    unknown.transferSize = 100;
    expect(task.progress, .55);
    expect(TransferProgress.crossPhase(task, upload: false).progress, .6);
  });

  test('Updated and legacy checkpoints restore without resetting bytes', () {
    final entry = _entry('saved', 100)
      ..status = RapidEntryStatus.uploading
      ..downloaded = 100
      ..payloadReady = true
      ..sent = 25
      ..uploadPhase = UploadPhase.uploading
      ..downloadSpeed = 100
      ..uploadSpeed = 20;
    final restored = RapidTransferEntry.fromJson(entry.toJson());
    expect(restored.progress, .625);
    expect(restored.uploadPhase, UploadPhase.uploading);
    expect(restored.downloadSpeed, 0);
    expect(restored.uploadSpeed, 0);
    final legacy = {...entry.toJson()}..remove('uploadPhase');
    expect(
      RapidTransferEntry.fromJson(legacy).uploadPhase,
      UploadPhase.uploading,
    );
    legacy['sent'] = 0;
    expect(
      RapidTransferEntry.fromJson(legacy).uploadPhase,
      UploadPhase.preparing,
    );
  });

  test('Unconfirmed checkpoints survive upgrades without dropping receipt', () {
    final entry = _entry('saved', 100)
      ..status = RapidEntryStatus.failed
      ..submitted = true
      ..confirmationPending = true
      ..submittedParent = 'folder'
      ..fileId = 'remote-id'
      ..md5 = '900150983cd24fb0d6963f7d28e17f72'
      ..sha1 = 'a9993e364706816aba3e25717850c26c9cd0d89d'
      ..payloadReady = true
      ..downloaded = 100
      ..sent = 100;
    final restored = RapidTransferEntry.fromJson(entry.toJson());
    expect(restored.confirmationPending, isTrue);
    expect(restored.submittedParent, 'folder');
    expect(restored.fileId, 'remote-id');
    expect(restored.sha1, entry.sha1);
    expect(restored.progress, .99);
    final legacy = {...entry.toJson()}
      ..remove('confirmationPending')
      ..remove('submittedParent')
      ..remove('sha1');
    expect(RapidTransferEntry.fromJson(legacy).confirmationPending, isTrue);
    legacy['status'] = 'uploaded';
    expect(RapidTransferEntry.fromJson(legacy).confirmationPending, isFalse);
    legacy
      ..['status'] = 'downloading'
      ..['submitted'] = false;
    expect(RapidTransferEntry.fromJson(legacy).confirmationPending, isFalse);
  });
}
