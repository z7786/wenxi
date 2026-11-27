import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/download_eta.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';

void main() {
  DownloadTask task({
    int speed = 10,
    int total = 100,
    int downloaded = 1,
    bool ready = false,
    String phase = '',
    DownloadStatus status = DownloadStatus.running,
  }) => DownloadTask(
    id: 'eta',
    spec: const DownloadSpec(url: 'https://example.test/a', fileName: 'a'),
    createdAt: 0,
    speed: speed,
    total: total,
    downloaded: downloaded,
    payloadReady: ready,
    phase: phase,
    status: status,
  );
  test('estimate follows current speed and rounds up', () {
    expect(downloadEta(task()), '约剩 10 秒');
    expect(downloadEta(task(speed: 20)), '约剩 5 秒');
    expect(downloadEta(task(total: 620)), '约剩 2 分钟');
    expect(downloadEta(task(total: 36601)), '约剩 1 小时 1 分钟');
    expect(downloadEta(task(total: 900001)), '约剩 1 天 1 小时');
  });
  test('unknown transfer is distinguished from finishing or paused work', () {
    expect(downloadEta(task(speed: 0)), '剩余时间估算中');
    expect(downloadEta(task(total: 0)), '剩余时间估算中');
    expect(downloadEta(task(ready: true)), isNull);
    expect(downloadEta(task(phase: '校验文件')), isNull);
    expect(downloadEta(task(downloaded: 100)), isNull);
    expect(downloadEta(task(status: DownloadStatus.paused)), isNull);
  });
}
