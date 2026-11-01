import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';

void main() {
  final original = DownloadTask.fromJson(
    const DownloadTask(
      id: 'video',
      spec: DownloadSpec(
        url: 'https://example.test/video?a=%2F&a=%2f',
        fileName: 'video.mp4',
        headers: {'Cookie': 'fixture-cookie'},
        source: {'platform': 'baidu', 'accountRevision': 7},
        cleanup: DownloadCleanup(url: 'https://example.test/cleanup'),
      ),
      createdAt: 12,
      status: DownloadStatus.running,
      downloaded: 10,
      total: 100,
      speed: 20,
      connections: 512,
      retries: 7,
      speedLimit: 12345,
      destination: 'content://fixture/folder',
      savedPath: 'content://fixture/video',
      error: 'previous error',
      recoveryAction: DownloadRecoveryAction.ucAuthorization,
      phase: '下载中',
      identity: RemoteIdentity(100, '"fixture-etag"', 'fixture-modified'),
      payloadReady: true,
      directOutput: true,
      hls: {'index': 4, 'bytes': 10, 'fingerprint': 'fixture'},
      connectionOptions: {'default': 64, 'baidu': 512},
    ).toJson(),
  );

  test('Progress updates retain source, recovery and checkpoint fields', () {
    for (final fields in <Json>[
      {'downloaded': 75, 'total': 100, 'speed': 65536, 'phase': ''},
      {'downloaded': 0, 'speed': 0},
      {'total': '200', 'speed': 1.9, 'phase': null},
      {'downloaded': null, 'total': 'invalid', 'speed': -1},
      {'phase': '等待连接'},
      {},
    ]) {
      final updated = original.update(fields);
      expect(
        updated.toJson(),
        DownloadTask.fromJson({...original.toJson(), ...fields}).toJson(),
        reason: '$fields',
      );
      expect(updated.spec, same(original.spec));
      expect(updated.identity, same(original.identity));
      expect(updated.hls, same(original.hls));
    }
    expect(
      original.update({'downloaded': 10, 'total': 100, 'speed': 20}),
      same(original),
    );
    expect(original.downloaded, 10);
    expect(original.phase, '下载中');
  });

  test(
    'Status, new sources and checkpoints use the existing decoding rules',
    () {
      final fields = <String, dynamic>{
        'status': 'paused',
        'connections': 999,
        'retries': -1,
        'speed': 0,
        'savedPath': null,
        'hls': {'index': 5, 'bytes': 90},
        'spec': {
          ...original.spec.toJson(),
          'url': 'https://example.test/refreshed?token=%2F',
        },
      };
      expect(
        original.update(fields).toJson(),
        DownloadTask.fromJson({...original.toJson(), ...fields}).toJson(),
      );
      expect(original.spec.url, 'https://example.test/video?a=%2F&a=%2f');
      expect(original.savedPath, 'content://fixture/video');
    },
  );
}
