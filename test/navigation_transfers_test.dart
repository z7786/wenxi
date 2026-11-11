import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/download/navigation_transfers.dart';
import 'package:asterlink/upload/upload_task.dart';

DownloadTask download(
  String id, {
  DownloadStatus status = DownloadStatus.running,
  int bytes = 0,
  int total = 1000,
}) => DownloadTask(
  id: id,
  spec: const DownloadSpec(
    url: 'https://example.com/file',
    fileName: 'test.zip',
  ),
  createdAt: 1,
  status: status,
  downloaded: bytes,
  total: total,
);

UploadTask upload(
  String id, {
  int bytes = 0,
  int total = 1000,
  UploadPhase phase = UploadPhase.uploading,
}) => UploadTask(
  id: id,
  session: const BrowseSession(
    platform: CloudPlatform.github,
    mode: BrowseMode.personal,
    title: 'test',
    rootId: 'root',
  ),
  parent: 'root',
  folderName: 'test',
  accountName: 'test',
  path: 'test.zip',
  name: 'test.zip',
  size: total,
  modifiedAt: 1,
  createdAt: 1,
  status: UploadStatus.running,
  phase: phase,
  sent: bytes,
);

class QueueFixture {
  final down = <String, DownloadTask>{}, up = <String, UploadTask>{};
  final changes = ChangeNotifier();
  late final state = NavigationTransfers(
    changes: changes,
    downloads: () => down.values.where((t) => t.active),
    uploads: () => up.values.where((t) => t.active),
    downloadById: (id) => down[id],
    uploadById: (id) => up[id],
  );
  void update() => changes.notifyListeners();
  void dispose() {
    state.dispose();
    changes.dispose();
  }
}

void main() {
  test(
    'hash matching contributes active count without pretending to upload bytes',
    () {
      final change = ChangeNotifier();
      var matching = 1;
      final state = NavigationTransfers(
        changes: change,
        downloads: () => [],
        uploads: () => [],
        downloadById: (_) => null,
        uploadById: (_) => null,
        rapid: () => matching,
      );
      expect(state.value.active, 1);
      expect(state.value.progress, -1);
      expect(state.value.description, contains('跨盘任务'));
      matching = 0;
      change.notifyListeners();
      expect(state.value.active, 0);
      state.dispose();
      change.dispose();
    },
  );
  test(
    'old completed and failed history stays quiet; both queues share the ring',
    () {
      final q = QueueFixture();
      addTearDown(q.dispose);
      q.down['old-failure'] = download(
        'old-failure',
        status: DownloadStatus.failed,
      );
      q.down['old-done'] = download(
        'old-done',
        status: DownloadStatus.completed,
        bytes: 1000,
      );
      expect(q.state.value, const NavigationTransferStatus());
      q.down['same'] = download('same', bytes: 500);
      q.up['same'] = upload('same', bytes: 100);
      q.update();
      expect(q.state.value.active, 2);
      expect(q.state.value.progress, 30);
      expect(q.state.value.description, contains('1 个下载，1 个上传'));
      q.down.remove('old-failure');
      q.down.remove('old-done');
      q.update();
      expect(q.state.value.completion, 0);
      expect(q.state.value.progress, 30);
    },
  );

  test(
    'finishing one file keeps its batch progress until both queues finish',
    () {
      final q = QueueFixture();
      addTearDown(q.dispose);
      q.down['a'] = download('a', bytes: 500);
      q.up['b'] = upload('b', bytes: 500);
      expect(q.state.value.progress, 50);
      q.down['a'] = download(
        'a',
        status: DownloadStatus.completed,
        bytes: 1000,
      );
      q.update();
      expect(q.state.value.active, 1);
      expect(q.state.value.progress, 75);
      expect(q.state.value.completion, 0);
      q.up['b']!
        ..sent = 1000
        ..status = UploadStatus.completed;
      q.update();
      expect(q.state.value.active, 0);
      expect(q.state.value.completion, 1);
      q.update();
      q.down.clear();
      q.up.clear();
      q.update();
      expect(q.state.value.completion, 1);
    },
  );

  test(
    'unknown sizes and upload validation do not pretend bytes are transferred',
    () {
      final q = QueueFixture();
      addTearDown(q.dispose);
      q.down['a'] = download('a', total: 0);
      q.up['b'] = upload('b', bytes: 1000, phase: UploadPhase.preparing);
      expect(q.state.value.progress, -1);
      q.down['a'] = download('a', bytes: 500);
      q.update();
      expect(q.state.value.progress, 25);
      q.up['b']!
        ..phase = UploadPhase.finishing
        ..sent = 1000;
      q.down['a'] = download('a', bytes: 1000);
      q.update();
      expect(q.state.value.progress, 99);
      expect(q.state.value.completion, 0);
    },
  );

  for (final terminal in [
    DownloadStatus.failed,
    DownloadStatus.paused,
    DownloadStatus.cancelled,
    null,
  ]) {
    test(
      'stopping/deleting a task ($terminal) does not announce completion',
      () {
        final q = QueueFixture();
        addTearDown(q.dispose);
        q.down['a'] = download('a');
        q.down['b'] = download('b');
        expect(q.state.value.active, 2);
        if (terminal == null) {
          q.down.remove('a');
        } else {
          q.down['a'] = download('a', status: terminal);
        }
        q.down['b'] = download(
          'b',
          status: DownloadStatus.completed,
          bytes: 1000,
        );
        q.update();
        expect(q.state.value.active, 0);
        expect(q.state.value.completion, 0);
        q.down['fresh'] = download('fresh');
        q.update();
        q.down['fresh'] = download(
          'fresh',
          status: DownloadStatus.completed,
          bytes: 1000,
        );
        q.update();
        expect(q.state.value.completion, 1);
      },
    );
  }

  test('resuming within a batch can still complete successfully', () {
    final q = QueueFixture();
    addTearDown(q.dispose);
    q.down['a'] = download('a');
    q.up['b'] = upload('b');
    expect(q.state.value.active, 2);
    q.down['a'] = download('a', status: DownloadStatus.paused);
    q.update();
    q.down['a'] = download('a');
    q.update();
    q.down['a'] = download('a', status: DownloadStatus.completed, bytes: 1000);
    q.up['b']!.status = UploadStatus.completed;
    q.update();
    expect(q.state.value.completion, 1);
  });

  test('sub-percent speed updates do not rebuild the navigation', () {
    final q = QueueFixture();
    addTearDown(q.dispose);
    q.down['a'] = download('a');
    var updates = 0;
    q.state.addListener(() => updates++);
    for (var i = 1; i < 10; i++) {
      q.down['a'] = download('a', bytes: i);
      q.update();
    }
    expect(updates, 0);
    q.down['a'] = download('a', bytes: 10);
    q.update();
    expect(updates, 1);
    expect(q.state.value.progress, 1);
  });
}
