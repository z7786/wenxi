import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'remote_control_support.dart';

class _UnreliableStore implements StateStore {
  final backing = StateStore.memory();
  bool fail = false;
  int writes = 0;
  Completer<void>? gate;
  @override
  Json get data => backing.data;
  @override
  Future<T> change<T>(T Function(Json) edit, {String? recoveryPassword}) async {
    writes++;
    await gate?.future;
    if (fail) throw StateError('disk unavailable');
    return backing.change(edit, recoveryPassword: recoveryPassword);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  RemoteControlService create(
    StateStore store,
    FakeControlFetcher fetcher,
    DateTime Function() clock,
  ) => RemoteControlService(
    store,
    enabled: true,
    platform: 'android',
    currentBuild: 44,
    configUrl: controlEndpoint,
    fetcher: fetcher,
    clock: clock,
  );

  test(
    'Public defaults and empty endpoints never contact an author service',
    () async {
      for (final url in [null, '', '  ']) {
        final fetcher = FakeControlFetcher();
        final control = url == null
            ? RemoteControlService(
                StateStore.memory(),
                platform: 'android',
                currentBuild: 44,
                fetcher: fetcher,
              )
            : RemoteControlService(
                StateStore.memory(),
                enabled: true,
                platform: 'android',
                currentBuild: 44,
                fetcher: fetcher,
                configUrl: url,
              );
        try {
          expect(control.configured, isFalse);
          expect(await control.refresh(), ControlRefreshResult.unconfigured);
          expect(fetcher.calls, isEmpty);
          await control.flushCache();
        } finally {
          control.close();
        }
      }
      final fetcher = FakeControlFetcher();
      final offline = RemoteControlService(
        StateStore.memory(
          controlCache(
            controlJson(disabled: ['uc']),
            endpoint: controlEndpoint,
          ),
        ),
        platform: 'android',
        currentBuild: 44,
        enabled: false,
        configUrl: controlEndpoint,
        fetcher: fetcher,
      );
      offline.setForeground(true);
      expect(
        await offline.refresh(force: true),
        ControlRefreshResult.unconfigured,
      );
      expect(offline.statusText, '离线模式');
      expect(offline.cloudEnabled(CloudPlatform.uc), isTrue);
      expect(fetcher.calls, isEmpty);
      offline.close();
    },
  );

  test(
    'Disabled modules ignore inactive leftover fields, then validate when activated',
    () {
      final json = controlJson()
        ..addAll({
          'announcement': {
            'enabled': false,
            'title': 3,
            'buttonUrl': 'http://bad',
          },
          'clouds': {
            'uc': {'enabled': true, 'message': false, 'expiresAt': 7},
          },
          'updates': {
            'windows': {
              'enabled': false,
              'build': -2,
              'force': 'true',
              'downloadUrl': 3,
            },
          },
          'help': {'enabled': false, 'url': 'javascript:bad'},
        });
      expect(RemoteControlDocument.parse(json).issues, isEmpty);
      (json['announcement'] as Map)['enabled'] = true;
      (json['clouds']['uc'] as Map)['enabled'] = false;
      (json['updates']['windows'] as Map)['enabled'] = true;
      (json['help'] as Map)['enabled'] = true;
      final doc = RemoteControlDocument.parse(json);
      expect(
        doc.issues.map((e) => e.section),
        containsAll(['announcement', 'clouds.uc', 'updates.windows', 'help']),
      );
      expect(() => doc.validated, throwsFormatException);
    },
  );

  test(
    'Each cloud and platform validates independently and reports a precise safe path',
    () {
      final previous = RemoteControlConfig.fromJson(
        controlJson(disabled: ['c139'], windowsBuild: 45, noticeId: 'old'),
      );
      final json = controlJson(
        revision: 2,
        androidBuild: 46,
        noticeId: 'new',
        help: true,
        disabled: ['uc'],
      )..['about'] = {'description': '新版介绍'};
      json['clouds']['c139'] = {'enabled': 'false', 'message': 'secret'};
      json['updates']['windows'] = {
        'enabled': true,
        'version': '1.0',
        'build': 47,
        'downloadUrl': Uri.https(
          'host.invalid',
          '/',
        ).replace(userInfo: 'user:supersecret').toString(),
      };
      final doc = RemoteControlDocument.parse(json, previous: previous);
      expect(doc.config.announcement!.id, 'new');
      expect(doc.config.updates['android']!.build, 46);
      expect(doc.config.updates['windows']!.build, 45);
      expect(doc.config.cloud(CloudPlatform.uc).enabled, isFalse);
      expect(doc.config.cloud(CloudPlatform.c139).enabled, isFalse);
      expect(doc.config.aboutText, '新版介绍');
      expect(doc.config.helpUrl, isNotNull);
      expect(doc.issues.map((e) => e.path), [
        'clouds.c139.enabled',
        'updates.windows.downloadUrl',
      ]);
      expect(
        jsonEncode(doc.issues.map((e) => e.toJson()).toList()),
        isNot(contains('supersecret')),
      );
      expect(doc.validSections, isNot(contains('clouds.c139')));
    },
  );

  test(
    'Missing modules intentionally reset earlier values and malformed containers isolate failures',
    () {
      final previous = RemoteControlConfig.fromJson(
        controlJson(
          noticeId: 'old',
          disabled: ['uc'],
          androidBuild: 50,
          help: true,
        ),
      );
      final cleared = RemoteControlDocument.parse({
        'schema': 1,
        'revision': 2,
      }, previous: previous);
      expect(cleared.config.announcement, isNull);
      expect(cleared.config.updates, isEmpty);
      expect(cleared.config.helpUrl, isNull);
      expect(cleared.config.cloud(CloudPlatform.uc).enabled, isTrue);
      final bad = RemoteControlDocument.parse({
        'schema': 1,
        'revision': 3,
        'clouds': [],
        'updates': null,
        'about': {'description': '有效内容'},
      }, previous: previous);
      expect(bad.config.cloud(CloudPlatform.uc).enabled, isFalse);
      expect(bad.config.updates['android']!.build, 50);
      expect(bad.config.aboutText, '有效内容');
      expect(bad.issues.length, CloudPlatform.values.length + 3);
      expect(
        bad.issues.map((issue) => issue.section),
        contains('updates.macos'),
      );
    },
  );

  for (final date in [
    '2026-02-30T00:00:00Z',
    '2026-10-01T24:00:00Z',
    '2026-10-01T00:00:00+08:00',
    'not-a-date',
    42,
  ]) {
    test(
      'Active restrictions reject invalid expiry $date with its exact field path',
      () {
        final json = controlJson(
          disabled: ['uc'],
          androidBuild: 50,
          force: true,
        );
        json['clouds']['uc']['expiresAt'] = date;
        json['updates']['android']['expiresAt'] = date;
        expect(RemoteControlDocument.parse(json).issues.map((e) => e.path), [
          'clouds.uc.expiresAt',
          'updates.android.expiresAt',
        ]);
      },
    );
  }

  test('UTC expiry round-trips without changing publication identity', () {
    for (final date in ['2026-10-01T00:00:00Z', '2028-02-29T23:59:59.12Z']) {
      final json = controlJson(disabled: ['uc'], androidBuild: 50, force: true);
      json['clouds']['uc']['expiresAt'] = date;
      json['updates']['android']['expiresAt'] = date;
      final doc = RemoteControlDocument.parse(json);
      expect(doc.issues, isEmpty);
      expect(
        doc.config.cloud(CloudPlatform.uc).expiresAt,
        DateTime.parse(date),
      );
      expect(
        RemoteControlDocument.parse(doc.config.toJson()).fingerprint,
        doc.fingerprint,
      );
    }
  });

  test(
    'Partial config preserves its old section timestamps and fingerprint across restart',
    () async {
      var now = controlNow;
      final store = StateStore.memory();
      final fetcher = FakeControlFetcher(
        controlJson(
          revision: 3,
          disabled: ['c139'],
          androidBuild: 50,
          force: true,
        ),
      );
      final control = create(store, fetcher, () => now);
      await control.refresh(force: true);
      now = now.add(const Duration(days: 6));
      final json = controlJson(revision: 4, noticeId: 'new');
      json['clouds']['c139'] = {'enabled': 'broken'};
      json['updates']['android'] = {
        'enabled': true,
        'version': 'next',
        'build': 55,
        'downloadUrl': 1,
      };
      fetcher.text = jsonEncode(json);
      expect(await control.refresh(force: true), ControlRefreshResult.partial);
      await control.flushCache();
      final reopened = create(
        StateStore.memory(store.data),
        fetcher,
        () => now,
      );
      try {
        expect(reopened.config.revision, 4);
        expect(reopened.issues.map((e) => e.path), [
          'clouds.c139.enabled',
          'updates.android.downloadUrl',
        ]);
        expect(
          reopened.diagnostics().obj('sections').obj('clouds.c139')['revision'],
          3,
        );
        expect(
          reopened
              .diagnostics()
              .obj('sections')
              .obj('announcement')['revision'],
          4,
        );
        expect(reopened.cloudEnabled(CloudPlatform.c139), isFalse);
        expect(reopened.requiredUpdate, isNotNull);
        expect(
          await reopened.refresh(force: true),
          ControlRefreshResult.partial,
        );
        now = now.add(const Duration(days: 1));
        expect(reopened.cloudEnabled(CloudPlatform.c139), isTrue);
        expect(reopened.requiredUpdate, isNull);
        expect(reopened.availableUpdate!.build, 50);
        expect(reopened.config.announcement!.id, 'new');
        json['clouds']['c139'] = {'enabled': false};
        fetcher.text = jsonEncode(json);
        expect(
          await reopened.refresh(force: true),
          ControlRefreshResult.partial,
        );
        expect(reopened.cloudEnabled(CloudPlatform.c139), isFalse);
        json['revision'] = 5;
        fetcher.text = jsonEncode(json);
        expect(
          await reopened.refresh(force: true),
          ControlRefreshResult.partial,
        );
        expect(reopened.cloudEnabled(CloudPlatform.c139), isFalse);
      } finally {
        control.close();
        reopened.close();
        await control.flushCache();
        await reopened.flushCache();
      }
    },
  );

  test(
    'Reordered publications and repairs apply with the same revision',
    () async {
      final fetcher = FakeControlFetcher(
        controlJson(noticeId: 'a', help: true),
      );
      final control = create(StateStore.memory(), fetcher, () => controlNow);
      try {
        await control.refresh();
        final reversed = Map.fromEntries(
          controlJson(noticeId: 'a', help: true).entries.toList().reversed,
        );
        fetcher.text = jsonEncode(reversed);
        expect(
          await control.refresh(force: true),
          ControlRefreshResult.success,
        );
        final unknown = controlJson(revision: 2)
          ..['clouds']['typo'] = {'enabled': false};
        fetcher.text = jsonEncode(unknown);
        expect(
          await control.refresh(force: true),
          ControlRefreshResult.partial,
        );
        unknown['clouds'].remove('typo');
        fetcher.text = jsonEncode(unknown);
        expect(
          await control.refresh(force: true),
          ControlRefreshResult.success,
        );
      } finally {
        control.close();
        await control.flushCache();
      }
    },
  );

  test(
    'Independent deadlines release only restrictions; repeated fetches never extend explicit expiry',
    () async {
      var now = controlNow;
      final cloudEnd = now.add(const Duration(hours: 1));
      final forceEnd = now.add(const Duration(hours: 2));
      final json = controlJson(
        disabled: ['uc'],
        androidBuild: 50,
        force: true,
        noticeId: 'a',
        help: true,
      );
      json['clouds']['uc']['expiresAt'] = cloudEnd.toUtc().toIso8601String();
      json['updates']['android']['expiresAt'] = forceEnd
          .toUtc()
          .toIso8601String();
      final fetcher = FakeControlFetcher(json);
      final control = create(StateStore.memory(), fetcher, () => now);
      try {
        await control.refresh();
        now = cloudEnd;
        await control.refresh(force: true);
        expect(control.cloudEnabled(CloudPlatform.uc), isTrue);
        expect(control.requiredUpdate, isNotNull);
        now = forceEnd;
        expect(control.requiredUpdate, isNull);
        expect(control.availableUpdate!.force, isFalse);
        now = now.add(const Duration(days: 100));
        expect(control.config.announcement, isNotNull);
        expect(control.availableUpdate!.build, 50);
        expect(control.config.helpUrl, isNotNull);
      } finally {
        control.close();
        await control.flushCache();
      }
    },
  );

  test(
    'Legacy cache migrates without renewing expired restrictions or losing information',
    () async {
      final now = controlNow.add(const Duration(days: 8));
      final state = StateStore.memory(
        controlCache(
          controlJson(
            revision: 3,
            disabled: ['uc'],
            androidBuild: 50,
            force: true,
            noticeId: 'old',
            help: true,
          ),
        ),
      );
      final fetcher = FakeControlFetcher(controlJson(revision: 2));
      final control = create(state, fetcher, () => now);
      try {
        expect(control.cloudEnabled(CloudPlatform.uc), isTrue);
        expect(control.availableUpdate!.force, isFalse);
        expect(control.unreadAnnouncement!.id, 'old');
        expect(control.config.helpUrl, isNotNull);
        expect(control.usingCache, isTrue);
        expect(await control.refresh(), ControlRefreshResult.success);
        expect(control.config.revision, 2);
      } finally {
        control.close();
      }
    },
  );

  testWidgets(
    'Failures retry at 10s, 30s, 2m and 5m then success restores the 15m poll',
    (tester) async {
      var now = controlNow;
      final fetcher = FakeControlFetcher()
        ..respond = (_) => throw TimeoutException('offline');
      final control = create(StateStore.memory(), fetcher, () => now);
      Future<void> advance(Duration amount) async {
        now = now.add(amount);
        await tester.pump(amount);
      }

      try {
        control.setForeground(true);
        await tester.pump();
        var calls = 1;
        for (final delay in [
          ...RemoteControlService.retryDelays,
          const Duration(minutes: 5),
        ]) {
          await advance(delay - const Duration(milliseconds: 1));
          expect(fetcher.calls.length, calls);
          await advance(const Duration(milliseconds: 1));
          expect(fetcher.calls.length, ++calls);
        }
        fetcher.respond = null;
        await advance(const Duration(minutes: 5));
        expect(fetcher.calls.length, ++calls);
        expect(control.lastError, isNull);
        await advance(const Duration(minutes: 14, seconds: 59));
        expect(fetcher.calls.length, calls);
        await advance(const Duration(seconds: 1));
        expect(fetcher.calls.length, ++calls);
        control.setForeground(false);
        await advance(const Duration(hours: 1));
        expect(fetcher.calls.length, calls);
      } finally {
        control.close();
      }
    },
  );

  testWidgets(
    'Foreground retries long backoff after 10 seconds but rapid focus changes do not spam requests',
    (tester) async {
      var now = controlNow;
      final fetcher = FakeControlFetcher()
        ..respond = (_) => throw TimeoutException('offline');
      final control = create(StateStore.memory(), fetcher, () => now);
      try {
        control.setForeground(true);
        await tester.pump();
        now = now.add(const Duration(seconds: 10));
        await tester.pump(const Duration(seconds: 10));
        expect(fetcher.calls.length, 2);
        control.setForeground(false);
        now = now.add(const Duration(seconds: 9));
        await tester.pump(const Duration(seconds: 9));
        control.setForeground(true);
        await tester.pump();
        expect(fetcher.calls.length, 2);
        control.setForeground(false);
        now = now.add(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        control.setForeground(true);
        await tester.pump();
        expect(fetcher.calls.length, 3);
        control.setForeground(false);
        control.setForeground(true);
        await tester.pump();
        expect(fetcher.calls.length, 3);
      } finally {
        control.close();
      }
    },
  );

  testWidgets(
    'A save failure keeps live restrictions and retries disk separately from network',
    (tester) async {
      var now = controlNow;
      final store = _UnreliableStore()..fail = true;
      final fetcher = FakeControlFetcher(
        controlJson(disabled: ['uc'], androidBuild: 50, force: true),
      );
      final control = create(store, fetcher, () => now);
      try {
        control.setForeground(true);
        await tester.pump();
        expect(control.cloudEnabled(CloudPlatform.uc), isFalse);
        expect(control.requiredUpdate!.build, 50);
        expect(control.cachePersisted, isFalse);
        expect(control.diagnostics()['cacheWriteFailed'], isTrue);
        expect(store.data[RemoteControlService.cacheKey], isNull);
        expect(fetcher.calls.length, 1);
        store.fail = false;
        now = now.add(const Duration(seconds: 10));
        await tester.pump(const Duration(seconds: 10));
        expect(store.writes, 2);
        expect(fetcher.calls.length, 1);
        expect(control.cachePersisted, isTrue);
        expect(control.lastError, isNull);
        expect(
          store.data
              .obj(RemoteControlService.cacheKey)
              .obj('control')['revision'],
          1,
        );
      } finally {
        control.close();
      }
    },
  );

  test(
    'A slow save drains the newest snapshot after shutdown instead of overwriting it with an older one',
    () async {
      final store = _UnreliableStore()..gate = Completer<void>();
      final fetcher = FakeControlFetcher(
        controlJson(revision: 3, disabled: ['uc']),
      );
      final control = create(store, fetcher, () => controlNow);
      expect(await control.refresh(), ControlRefreshResult.success);
      expect(control.cloudEnabled(CloudPlatform.uc), isFalse);
      fetcher.text = jsonEncode(controlJson(revision: 4, help: true));
      expect(await control.refresh(force: true), ControlRefreshResult.success);
      expect(control.cloudEnabled(CloudPlatform.uc), isTrue);
      control.close();
      store.gate!.complete();
      await control.flushCache();
      expect(store.writes, 2);
      expect(
        store.data
            .obj(RemoteControlService.cacheKey)
            .obj('control')['revision'],
        4,
      );
      final reopened = create(
        StateStore.memory(store.data),
        FakeControlFetcher(),
        () => controlNow,
      );
      expect(reopened.config.revision, 4);
      expect(reopened.config.helpUrl, isNotNull);
      reopened.close();
    },
  );

  test('Shutdown flush retries a previously failed save once', () async {
    final store = _UnreliableStore()..fail = true;
    final control = create(
      store,
      FakeControlFetcher(controlJson(noticeId: 'a')),
      () => controlNow,
    );
    await control.refresh();
    await control.flushCache();
    expect(control.cachePersisted, isFalse);
    store.fail = false;
    control.close();
    await control.flushCache();
    expect(control.cachePersisted, isTrue);
    expect(
      store.data.obj(RemoteControlService.cacheKey).obj('control')['revision'],
      1,
    );
  });
}
