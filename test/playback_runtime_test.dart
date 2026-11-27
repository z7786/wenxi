import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/playback/playback_runtime.dart';

void main() {
  test('concurrent preload and playback share one initialization', () async {
    final pending = Completer<void>();
    var starts = 0;
    final runtime = PlaybackRuntime(
      initialize: () {
        starts++;
        return pending.future;
      },
    );
    runtime.preload();
    final opening = runtime.ensureInitialized();
    expect(identical(opening, runtime.ensureInitialized()), isTrue);
    expect(runtime.ready, isFalse);
    expect(starts, 1);
    pending.complete();
    await opening;
    await runtime.ensureInitialized();
    runtime.preload();
    expect(runtime.ready, isTrue);
    expect(runtime.failure, isNull);
    expect(starts, 1);
  });

  test(
    'background failure is handled and only a playback request retries',
    () async {
      final pending = Completer<void>();
      var starts = 0;
      final runtime = PlaybackRuntime(
        initialize: () {
          starts++;
          return pending.future;
        },
      );
      runtime.preload();
      final opening = runtime.ensureInitialized();
      final checked = expectLater(
        opening,
        throwsA(isA<PlaybackRuntimeUnavailable>()),
      );
      pending.completeError(TypeError());
      await checked;
      expect(runtime.ready, isFalse);
      expect(runtime.failure, isNotNull);
      runtime.preload();
      expect(starts, 1);
      await expectLater(
        runtime.ensureInitialized(),
        throwsA(isA<PlaybackRuntimeUnavailable>()),
      );
      expect(starts, 2);
    },
  );

  test(
    'a synchronous load failure permits retry and logs as a feature error',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-runtime-test-',
      );
      final log = DiagnosticLog.open(directory);
      final previous = DiagnosticLog.active;
      DiagnosticLog.active = log;
      var starts = 0;
      final runtime = PlaybackRuntime(
        initialize: () {
          if (++starts == 1) throw TypeError();
          return Future.value();
        },
      );
      try {
        await expectLater(
          runtime.ensureInitialized(),
          throwsA(isA<PlaybackRuntimeUnavailable>()),
        );
        final failures = log.entries().where(
          (e) => e.event == 'player.runtime_load_failed',
        );
        expect(failures, hasLength(1));
        expect(failures.single.level, 'error');
        expect(
          log.entries().where((e) => e.event == 'app.bootstrap_failed'),
          isEmpty,
        );
        await runtime.ensureInitialized();
        expect(starts, 2);
        expect(runtime.ready, isTrue);
        expect(runtime.failure, isNull);
      } finally {
        DiagnosticLog.active = previous;
        log.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
