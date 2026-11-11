import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_seek_queue.dart';

void main() {
  test(
    'Rapid seeks discard obsolete queued targets and finish at the latest',
    () async {
      final gate = Completer<void>(), sent = <Duration>[];
      final queue = PlaybackSeekQueue((position) async {
        sent.add(position);
        if (sent.length == 1) await gate.future;
      });
      final first = queue.seek(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      final middle = queue.seek(const Duration(seconds: 20));
      final last = queue.seek(const Duration(seconds: 30));
      gate.complete();
      await Future.wait([first, middle, last]);
      expect(sent, [const Duration(seconds: 10), const Duration(seconds: 30)]);
    },
  );
  test('Closing drops queued work and a failed seek can be retried', () async {
    final gate = Completer<void>(), sent = <Duration>[];
    final queue = PlaybackSeekQueue((p) async {
      sent.add(p);
      await gate.future;
    });
    final first = queue.seek(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final last = queue.seek(const Duration(seconds: 10));
    queue.close();
    gate.complete();
    await Future.wait([first, last]);
    expect(sent, [Duration.zero]);
    var count = 0;
    final retry = PlaybackSeekQueue((_) async {
      if (++count == 1) throw StateError('seek failed');
    });
    await expectLater(retry.seek(Duration.zero), throwsStateError);
    await retry.seek(const Duration(seconds: 1));
    expect(count, 2);
  });
}
