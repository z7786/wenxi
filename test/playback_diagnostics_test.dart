import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/diagnostics/diagnostic_bundle.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'package:asterlink/playback/recent_playback.dart';
import 'player_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DiagnosticLog log;
  late PlaybackFixture fixture;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('asterlink-player-log-');
    log = DiagnosticLog.open(directory);
    DiagnosticLog.active = log;
    fixture = PlaybackFixture(
      renewable: true,
      platforms: List.filled(3, CloudPlatform.quark),
    );
  });
  tearDown(() async {
    await fixture.controller.close();
    DiagnosticLog.active = null;
    log.close();
    directory.deleteSync(recursive: true);
  });
  List<LogEntry> errors(String event) =>
      log.entries(errorsOnly: true).where((e) => e.event == event).toList();
  Map fields(LogEntry entry) => entry.data['fields'] as Map;

  test(
    'Source resolution failures persist with a stack and safe context',
    () async {
      fixture.prepareBarrier = (_, _) async => throw const AppException(
        '无法连接 https://example.invalid/private-movie?token=private-token',
      );
      await fixture.controller.start();
      expect(fixture.controller.error, isNotEmpty);
      final entry = errors('player.load_failed').single;
      expect(fields(entry)['stage'], 'source');
      expect(fields(entry)['platform'], CloudPlatform.quark.key);
      expect(
        fields(entry)['playback'],
        DiagnosticLog.reference(fixture.entries.first.key),
      );
      expect(entry.data['stack'], isNotEmpty);
      expect(log.exportFiles().values.join(), isNot(contains('private-')));
      final reopened = DiagnosticLog.open(directory);
      expect(
        reopened
            .entries(errorsOnly: true)
            .any((e) => e.event == 'player.load_failed'),
        isTrue,
      );
      reopened.close();
    },
  );

  test(
    'Playback interruptions, automatic recovery and final failure appear in the exported error log',
    () async {
      await fixture.controller.start();
      fixture.current.emit(
        fixture.current.state.copyWith(position: const Duration(seconds: 95)),
      );
      fixture.current
        ..failure = PlaybackFailure.http(503)
        ..fail();
      await until(() => fixture.preparations == 2 && fixture.controller.ready);
      fixture.current
        ..failure = PlaybackFailure.http(403)
        ..fail();
      final entries = errors('player.playback_failed');
      expect(entries, hasLength(2));
      final first = entries.singleWhere((e) => fields(e)['status'] == 503);
      final last = entries.singleWhere((e) => fields(e)['status'] == 403);
      expect(fields(first)['recovery'], 'refresh');
      expect(fields(last)['recovery'], 'none');
      expect(fields(last)['positionMs'], 95000);
      expect(fields(last)['durationMs'], 600000);
      expect(fields(last)['connections'], fixture.controller.connections);
      expect(fields(last)['decoder'], 'hardware');
      expect(fixture.controller.error, contains('失效'));
      expect(
        log.entries().where(
          (e) =>
              e.event == 'player.ready' &&
              fields(e)['automaticRecovery'] == true,
        ),
        hasLength(1),
      );
      final bundle = DiagnosticBundle(
        log,
        snapshot: () => {},
        nativeEnabled: false,
      );
      final files = ZipDecoder().decodeBytes(await bundle.build()).files;
      final exported = files
          .where((f) => f.name.startsWith('logs/'))
          .map((f) => utf8.decode(f.content as List<int>))
          .join('\n');
      expect(exported, contains('player.playback_failed'));
      expect(exported, contains('"level":"error"'));
      for (final secret in [
        'fixture-secret',
        'example.invalid',
        fixture.entries.first.name,
      ]) {
        expect(exported, isNot(contains(secret)));
      }
    },
  );

  test(
    'Initialization errors identify the failing phase and decoder fallback',
    () async {
      fixture.configureBackend = (backend) => backend
        ..describeVideo()
        ..failOpen = true;
      await fixture.controller.start();
      expect(errors('player.hardware_fallback'), hasLength(1));
      final failure = errors('player.load_failed').single;
      expect(fields(failure)['stage'], 'backend_open');
      expect(fields(failure)['decoder'], 'software');
      expect(fields(failure)['recovery'], 'none');
      expect(failure.data['stack'], isNotEmpty);
      expect(errors('player.playback_failed'), isEmpty);
    },
  );

  test(
    'A backend play command exception is recorded even if it has no stream error',
    () async {
      await fixture.controller.start();
      fixture.current.throwOnPlay = true;
      await fixture.controller.play();
      expect(fixture.controller.notice, contains('播放操作'));
      final entry = errors('player.command_failed').single;
      expect(fields(entry)['operation'], 'play');
      expect(fields(entry)['stage'], 'command');
      expect(entry.data['stack'], isNotEmpty);
    },
  );

  for (final close in [false, true]) {
    test(
      '${close ? 'Closing' : 'Switching episodes'} does not report an obsolete request as a playback failure',
      () async {
        final answer = Completer<void>();
        fixture.prepareBarrier = (_, number) =>
            number == 1 ? answer.future : Future.value();
        final pending = fixture.controller.start();
        await until(() => fixture.preparations == 1);
        Future<void>? closing;
        if (close) {
          closing = fixture.controller.close();
        } else {
          await fixture.controller.next();
        }
        answer.completeError(const AppException('obsolete request failed'));
        await pending;
        await closing;
        expect(errors('player.load_failed'), isEmpty);
        expect(errors('player.playback_failed'), isEmpty);
      },
    );
  }

  test(
    'Failure to restore a deleted recent file is logged; canceled restoration is not',
    () async {
      final files = FakeFiles(directory);
      final path = '${directory.path}/private-movie.mp4';
      files.availability[path] = FileAvailability.missing;
      final services = AppServices(
        controlEnabled: false,
        store: StateStore.memory(),
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: files,
        http: FakeHttp(),
        platformFeatures: false,
      );
      addTearDown(services.close);
      final record = PlaybackRecord(
        'private-record',
        PlaybackBookmark(
          name: 'private-movie.mp4',
          position: Duration.zero,
          duration: const Duration(minutes: 10),
          updatedAt: 1,
          source: PlaybackSource.local(path: path),
        ),
      );
      await expectLater(
        restoreRecentPlayback(services, record),
        throwsA(isA<AppException>()),
      );
      final entry = errors('player.restore_failed').single;
      expect(fields(entry)['sourceKind'], 'local');
      expect(fields(entry)['stage'], 'restore');
      expect(entry.detail, isNot(contains('private-')));
      final canceled = RequestScope()..cancel();
      await expectLater(
        canceled.run(() => restoreRecentPlayback(services, record)),
        throwsA(isA<AppException>()),
      );
      expect(errors('player.restore_failed'), hasLength(1));
    },
  );

  test(
    'Turning off recording also suppresses playback failure entries',
    () async {
      log.setEnabled(false);
      fixture.configureBackend = (backend) => backend
        ..describeVideo()
        ..failOpen = true;
      await fixture.controller.start();
      expect(fixture.controller.error, isNotEmpty);
      expect(log.entries(errorsOnly: true), isEmpty);
    },
  );
}
