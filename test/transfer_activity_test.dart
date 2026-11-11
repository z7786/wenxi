import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/download/download_activity.dart';
import 'package:asterlink/download/transfer_activity.dart';

void main() {
  test(
    'hash matching remains active independently of download and upload queues',
    () async {
      var matching = const DownloadActivity(active: 1, text: '秒传匹配 1 个任务');
      final notices = <Json>[];
      final service = TransferActivity(
        downloads: () => const DownloadActivity.idle(),
        uploads: () => const DownloadActivity.idle(),
        rapid: () => matching,
        publish: (s) async {
          notices.add(s);
        },
      );
      await service.sync();
      expect(notices.last.integer('active'), 1);
      expect(notices.last.integer('rapid'), 1);
      expect(notices.last.integer('progress'), -1);
      matching = const DownloadActivity.idle();
      await service.sync();
      expect(notices.last.integer('active'), 0);
    },
  );
  test(
    'LAN listener remains active when downloads finish and stops explicitly',
    () async {
      var down = const DownloadActivity(active: 1, text: 'downloading');
      var local = const DownloadActivity(active: 1, text: '设备互联已开启');
      final notices = <Json>[];
      final activity = TransferActivity(
        downloads: () => down,
        uploads: () => const DownloadActivity.idle(),
        lan: () => local,
        publish: (value) async {
          notices.add(value);
        },
      );
      await activity.sync();
      expect(notices.last.integer('active'), 2);
      expect(notices.last.integer('lan'), 1);
      down = const DownloadActivity.idle();
      await activity.sync();
      expect(notices.last.integer('active'), 1);
      expect(notices.last.str('text'), '设备互联已开启');
      local = const DownloadActivity.idle();
      await activity.sync();
      expect(notices.last.integer('active'), 0);
      expect(notices.last.containsKey('lan'), isFalse);
    },
  );
  test(
    'download finishing cannot stop upload service and idle waits for both queues',
    () async {
      var down = const DownloadActivity(active: 1, text: 'download');
      var up = const DownloadActivity(active: 1, text: 'upload');
      final notices = <Json>[];
      final coordinator = TransferActivity(
        downloads: () => down,
        uploads: () => up,
        publish: (s) async {
          notices.add(s);
        },
      );
      await coordinator.sync();
      down = const DownloadActivity.idle();
      await coordinator.sync();
      expect(notices.last.integer('active'), 1);
      expect(notices.last.integer('uploads'), 1);
      expect(notices.last.str('text'), contains('上传'));
      up = const DownloadActivity.idle();
      await coordinator.sync();
      expect(notices.last.integer('active'), 0);
    },
  );
  test(
    'queued idle updates recompute state after earlier publication completes',
    () async {
      var up = const DownloadActivity.idle();
      final gate = Completer<void>(), notices = <Json>[];
      final coordinator = TransferActivity(
        downloads: () => const DownloadActivity.idle(),
        uploads: () => up,
        publish: (s) async {
          notices.add(s);
          if (notices.length == 1) await gate.future;
        },
      );
      final first = coordinator.sync();
      await Future<void>.delayed(Duration.zero);
      final second = coordinator.sync();
      up = const DownloadActivity(active: 1, text: 'upload');
      gate.complete();
      await first;
      await second;
      expect(notices.last.integer('active'), 1);
    },
  );
}
