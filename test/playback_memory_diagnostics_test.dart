import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/playback/playback_diagnostics.dart';

void main() {
  late DiagnosticLog log;
  setUp(() {
    log = DiagnosticLog.open(null);
    DiagnosticLog.active = log;
  });
  tearDown(() {
    DiagnosticLog.active = null;
    log.close();
  });
  List<LogEntry> samples() =>
      log.entries().where((e) => e.event == 'player.memory_sample').toList();

  test(
    'Samples are throttled, numeric only and correlated with decoding',
    () async {
      var calls = 0;
      final recorder = PlaybackDiagnostics(
        readMemory: () async => {
          'rssKb': 100000 + 1000 * calls++,
          'nativeHeapAllocatedBytes': 40000,
          'pssKb': 90000,
          'cookie': 'private-credential',
          'path': '/storage/private-movie',
          'threadCount': 'private-value',
        },
      );
      recorder.begin({'playbackSource': 'source-a'});
      await recorder.sample(
        Duration.zero,
        () => {'hwdecCurrent': 'mediacodec-copy'},
      );
      for (var i = 2; i < 30; i += 2) {
        await recorder.sample(Duration(seconds: i), () => {});
      }
      expect(calls, 1);
      await recorder.sample(
        const Duration(seconds: 30),
        () => {'positionMs': 30000},
      );
      expect(calls, 2);
      expect(samples(), hasLength(2));
      final entries = samples().map((e) => e.data['fields'] as Map).toList();
      expect(entries.first['memoryDelta'], {
        'rssKb': 1000,
        'pssKb': 0,
        'nativeHeapAllocatedBytes': 0,
      });
      expect(entries.first['playbackSource'], 'source-a');
      expect(entries.last['hwdecCurrent'], 'mediacodec-copy');
      expect(log.exportFiles().values.join(), isNot(contains('private-')));
    },
  );

  test(
    'Switching the source discards an in-flight sample and resets baseline',
    () async {
      final pending = Completer<Object?>();
      var calls = 0;
      final recorder = PlaybackDiagnostics(
        readMemory: () =>
            calls++ == 0 ? pending.future : Future.value({'rssKb': 20000}),
      );
      recorder.begin({'playbackSource': 'old'});
      final first = recorder.sample(Duration.zero, () => {});
      recorder.begin({'playbackSource': 'new'});
      pending.complete({'rssKb': 10000});
      await first;
      expect(samples(), isEmpty);
      await recorder.sample(Duration.zero, () => {});
      expect((samples().single.data['fields'] as Map)['playbackSource'], 'new');
      expect(
        (samples().single.data['fields'] as Map)['memoryPhase'],
        'baseline',
      );
    },
  );

  test(
    'Close drops in-flight playback samples but records released memory',
    () async {
      final pending = Completer<Object?>();
      var calls = 0;
      final recorder = PlaybackDiagnostics(
        readMemory: () =>
            calls++ == 0 ? pending.future : Future.value({'rssKb': 20000}),
      );
      recorder.begin({'playbackSource': 'source'});
      final first = recorder.sample(Duration.zero, () => {});
      recorder.stop();
      pending.complete({'rssKb': 10000});
      await first;
      await recorder.sample(const Duration(seconds: 30), () => {});
      expect(samples(), isEmpty);
      await recorder.afterClose({'closePhase': 'stopped'});
      expect(
        log.entries().where((e) => e.event == 'player.memory_after_close'),
        hasLength(1),
      );
      await recorder.afterClose({}, phase: 'settled');
      final closed = log.entries().where(
        (e) => e.event == 'player.memory_after_close',
      );
      expect(closed, hasLength(2));
      expect((closed.first.data['fields'] as Map)['memoryPhase'], 'settled');
      expect(calls, 3);
    },
  );

  test('Disabled logging and failing bridges cannot affect playback', () async {
    var calls = 0;
    final recorder = PlaybackDiagnostics(
      readMemory: () async {
        calls++;
        throw StateError('bridge unavailable');
      },
    );
    recorder.begin({});
    log.setEnabled(false);
    await recorder.sample(Duration.zero, () => {});
    await recorder.afterClose({});
    expect(calls, 0);
    log.setEnabled(true);
    await recorder.sample(Duration.zero, () => {});
    await recorder.afterClose({});
    expect(calls, 2);
    expect(samples(), isEmpty);
  });

  test(
    'Slow counters back off and skipped samples do not build fields',
    () async {
      var calls = 0, fieldsBuilt = 0;
      final recorder = PlaybackDiagnostics(
        readMemory: () async {
          calls++;
          return {'rssKb': 10000, 'sampleCostMs': 150};
        },
      );
      Map<String, Object?> fields() {
        fieldsBuilt++;
        return {'videoCodec': 'hevc'};
      }

      recorder.begin({});
      await recorder.sample(Duration.zero, fields);
      await recorder.sample(const Duration(seconds: 30), fields);
      await recorder.sample(const Duration(seconds: 90), fields);
      expect(calls, 1);
      expect(fieldsBuilt, 1);
      await recorder.sample(const Duration(seconds: 120), fields);
      expect(calls, 2);
      expect(fieldsBuilt, 2);
      expect(
        (samples().first.data['fields'] as Map)['memorySampleIntervalMs'],
        120000,
      );
    },
  );
}
