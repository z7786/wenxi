import 'dart:async';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/batch_share.dart';
import 'package:asterlink/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

const files = [
  CloudFile(id: 'a', name: 'a.mp4'),
  CloudFile(id: 'b', name: 'b.txt'),
  CloudFile(id: 'c', name: 'c.zip'),
];
const options = ShareOptions('combined', expiryDays: 7, passcode: '1234');
void main() {
  test(
    'creates one link per item with its own title and shared options',
    () async {
      final job = BatchShareJob(files, options);
      final calls = <String>[];
      await job.run((file, option) async {
        calls.add(file.id);
        expect(option.title, file.name);
        expect(option.expiryDays, 7);
        expect(option.passcode, '1234');
        return ShareCreation(
          'https://share.test/${file.id}',
          '1234',
          option.title,
        );
      }, guard: () {});
      expect(calls, ['a', 'b', 'c']);
      expect(job.value.succeeded, 3);
      expect(job.value.finished, isTrue);
      expect(job.value.text, contains('c.zip\nhttps://share.test/c'));
      job.dispose();
    },
  );

  test(
    'individual failure retains links and continues without retry',
    () async {
      final job = BatchShareJob(files, options);
      final calls = <String>[];
      await job.run((file, option) async {
        calls.add(file.id);
        if (file.id == 'b') throw const AppException('分享受限');
        return ShareCreation('https://share.test/${file.id}', '', option.title);
      }, guard: () {});
      expect(calls, ['a', 'b', 'c']);
      expect(job.value.succeeded, 2);
      expect(job.value.failed, 1);
      expect(job.value.entries[1].error, '分享受限');
      expect(job.value.text, isNot(contains('b.txt')));
      job.dispose();
    },
  );

  test(
    'stop interrupts an outstanding request and preserves completed links',
    () async {
      final job = BatchShareJob(files, options);
      final pending = Completer<ShareCreation>();
      final entered = Completer<void>();
      final calls = <String>[];
      final running = job.run((file, option) async {
        calls.add(file.id);
        if (file.id == 'b') {
          entered.complete();
          return pending.future;
        }
        return ShareCreation('https://share.test/${file.id}', '', option.title);
      }, guard: () {});
      await entered.future;
      job.stop();
      await running;
      expect(calls, ['a', 'b']);
      expect(job.value.succeeded, 1);
      expect(job.value.finished, isTrue);
      expect(job.value.entries.last.error, contains('结果未确认'));
      final report = job.value;
      pending.complete(const ShareCreation('late', '', 'b'));
      await Future<void>.delayed(Duration.zero);
      expect(job.value, same(report));
      job.dispose();
    },
  );

  test(
    'account changes halt further creation and retain accepted results',
    () async {
      final job = BatchShareJob(files, options);
      var changed = false;
      await job.run(
        (file, option) async {
          changed = true;
          return ShareCreation(
            'https://share.test/${file.id}',
            '',
            option.title,
          );
        },
        guard: () {
          if (changed) throw const AppException('账号已变化');
        },
      );
      expect(job.value.entries.length, 1);
      expect(job.value.reason, '账号已变化');
      job.dispose();
    },
  );
}
