import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'remote_control_support.dart';
import 'support.dart' show until;

void main() {
  for (final platform in ['ios', 'macos']) {
    test(
      '$platform uses remote updates, expiry, cloud controls and saved cache',
      () async {
        final store = StateStore.memory({});
        addTearDown(store.dispose);
        var now = controlNow;
        final root = controlJson(disabled: ['quark'], noticeId: 'apple');
        (root['updates'] as Map)[platform] = {
          'enabled': true,
          'force': true,
          'version': '2.2.1',
          'build': 221,
          'downloadUrl': 'https://example.test/$platform',
          'expiresAt': now
              .toUtc()
              .add(const Duration(hours: 1))
              .toIso8601String(),
        };
        final control = RemoteControlService(
          store,
          platform: platform,
          currentBuild: 220,
          configUrl: controlEndpoint,
          enabled: true,
          fetcher: FakeControlFetcher(root),
          clock: () => now,
        );
        addTearDown(control.close);
        expect(await control.refresh(), ControlRefreshResult.success);
        expect(control.requiredUpdate!.build, 221);
        expect(control.cloudEnabled(CloudPlatform.quark), isFalse);
        await until(() => control.cachePersisted);
        control.close();
        final cached = RemoteControlService(
          store,
          platform: platform,
          currentBuild: 220,
          configUrl: controlEndpoint,
          enabled: true,
          fetcher: FakeControlFetcher(),
          clock: () => now,
        );
        addTearDown(cached.close);
        expect(cached.requiredUpdate!.build, 221);
        expect(cached.errorForSection('updates.$platform'), isNull);
        now = now.add(const Duration(hours: 2));
        expect(cached.requiredUpdate, isNull);
        expect(cached.availableUpdate!.force, isFalse);
        expect(cached.config.announcement, isNotNull);
      },
    );
  }

  late StateStore store;
  late FakeControlFetcher fetcher;
  late RemoteControlService control;
  late DateTime now;
  setUp(() {
    now = controlNow;
    store = StateStore.memory();
    fetcher = FakeControlFetcher();
    control = RemoteControlService(
      store,
      enabled: true,
      platform: 'android',
      currentBuild: 44,
      configUrl: controlEndpoint,
      fetcher: fetcher,
      clock: () => now,
    );
  });
  tearDown(() => control.close());

  test(
    'About changes apply without a newer revision and survive an offline restart',
    () async {
      fetcher.text = jsonEncode(
        controlJson()..['about'] = {'description': '第一版介绍'},
      );
      expect(await control.refresh(force: true), ControlRefreshResult.success);
      fetcher.text = jsonEncode(
        controlJson()..['about'] = {'description': '第二版介绍'},
      );
      expect(await control.refresh(force: true), ControlRefreshResult.success);
      expect(control.config.aboutText, '第二版介绍');
      final restarted = RemoteControlService(
        store,
        enabled: true,
        platform: 'windows',
        currentBuild: 50,
        configUrl: controlEndpoint,
        fetcher: FakeControlFetcher(),
        clock: () => now,
      );
      expect(restarted.config.aboutText, '第二版介绍');
      restarted.close();
    },
  );

  test('An unsafe endpoint never fetches or adopts another cache', () async {
    for (final endpoint in [
      'http://insecure.test/control.json',
      'https://host.test/control.json#fragment',
    ]) {
      final empty = RemoteControlService(
        StateStore.memory(controlCache(controlJson(disabled: ['uc']))),
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: endpoint,
        fetcher: fetcher,
        clock: () => now,
      );
      empty.setForeground(true);
      expect(
        await empty.refresh(force: true),
        ControlRefreshResult.unconfigured,
      );
      expect(empty.cloudEnabled(CloudPlatform.uc), isTrue);
      empty.close();
    }
    expect(fetcher.calls, isEmpty);
  });

  test(
    'Startup immediately restores endpoint-scoped cache without network I/O',
    () {
      final state = StateStore.memory(
        controlCache(controlJson(disabled: ['uc'])),
      );
      final cached = RemoteControlService(
        state,
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        fetcher: fetcher,
        clock: () => now,
      );
      final other = RemoteControlService(
        state,
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: 'https://different.example.test/control.json',
        clock: () => now,
      );
      addTearDown(cached.close);
      addTearDown(other.close);
      expect(cached.cloudEnabled(CloudPlatform.uc), isFalse);
      expect(
        () => cached.checkCloud(CloudPlatform.uc),
        throwsA(isA<AppException>()),
      );
      expect(other.cloudEnabled(CloudPlatform.uc), isTrue);
      expect(fetcher.calls, isEmpty);
    },
  );

  test(
    'Coalesces concurrent refreshes and atomically persists all sections',
    () async {
      final response = Completer<String>();
      fetcher.respond = (_) => response.future;
      final first = control.refresh(force: true);
      final second = control.refresh(force: true);
      expect(identical(first, second), isTrue);
      expect(control.checking, isTrue);
      expect(fetcher.calls, hasLength(1));
      response.complete(
        jsonEncode(
          controlJson(
            noticeId: 'a',
            androidBuild: 45,
            disabled: ['uc'],
            help: true,
          ),
        ),
      );
      expect(await first, ControlRefreshResult.success);
      expect(control.checking, isFalse);
      expect(control.cloudEnabled(CloudPlatform.uc), isFalse);
      expect(control.availableUpdate!.build, 45);
      expect(control.unreadAnnouncement!.id, 'a');
      expect(
        control.config.helpUrl.toString(),
        'https://help.example.test/guide#cloud',
      );
      expect(
        store.data.obj(RemoteControlService.cacheKey)['control'],
        control.config.toJson(),
      );
    },
  );

  test(
    'Invalid JSON and network failures keep the last good config without renewing its age',
    () async {
      fetcher.text = jsonEncode(controlJson(revision: 3, disabled: ['uc']));
      await control.refresh(force: true);
      final snapshot = jsonEncode(store.data);
      final fetched = control.lastSuccess;
      now = now.add(const Duration(days: 1));
      fetcher.text = '<html>unavailable</html>';
      expect(await control.refresh(force: true), ControlRefreshResult.failed);
      expect(control.cloudEnabled(CloudPlatform.uc), isFalse);
      expect(control.lastError, '在线配置格式有误，请联系维护者修正');
      expect(control.diagnostics()['lastFailure'], 'invalid_config');
      expect(control.lastSuccess, fetched);
      expect(jsonEncode(store.data), snapshot);
      fetcher.respond = (_) => throw TimeoutException('offline');
      expect(await control.refresh(force: true), ControlRefreshResult.failed);
      expect(control.lastSuccess, fetched);
      expect(control.lastError, isNotNull);
      expect(control.diagnostics()['lastFailure'], 'fetch_failed');
    },
  );

  test(
    'Latest fetched content applies with an identical, lower or missing revision',
    () async {
      fetcher.text = jsonEncode(controlJson(revision: 3, disabled: ['uc']));
      await control.refresh(force: true);
      now = now.add(const Duration(hours: 1));
      expect(await control.refresh(force: true), ControlRefreshResult.success);
      expect(control.lastSuccess, now);
      for (final revision in [3, 2, 0]) {
        fetcher.text = jsonEncode(controlJson(revision: revision));
        expect(
          await control.refresh(force: true),
          ControlRefreshResult.success,
        );
        expect(control.cloudEnabled(CloudPlatform.uc), isTrue);
        expect(control.diagnostics()['lastFailure'], isNull);
        fetcher.text = jsonEncode(
          controlJson(revision: revision, disabled: ['uc']),
        );
        expect(
          await control.refresh(force: true),
          ControlRefreshResult.success,
        );
        expect(control.cloudEnabled(CloudPlatform.uc), isFalse);
      }
      fetcher.text = jsonEncode(
        controlJson()
          ..remove('revision')
          ..remove('schema'),
      );
      expect(await control.refresh(force: true), ControlRefreshResult.success);
      expect(control.cloudEnabled(CloudPlatform.uc), isTrue);
      expect(control.lastError, isNull);
      expect(control.diagnostics()['lastFailure'], isNull);
    },
  );

  test(
    'Seven-day stale restrictions expire while informational content remains available',
    () async {
      fetcher.text = jsonEncode(
        controlJson(
          revision: 3,
          noticeId: 'a',
          disabled: ['uc'],
          androidBuild: 45,
          help: true,
        ),
      );
      await control.refresh(force: true);
      now = now.add(RemoteControlService.legacyRestrictionLifetime);
      expect(control.hasFreshConfig, isFalse);
      expect(control.cloudEnabled(CloudPlatform.uc), isTrue);
      expect(control.availableUpdate!.build, 45);
      expect(control.unreadAnnouncement!.id, 'a');
      expect(control.config.helpUrl, isNotNull);
      fetcher.text = jsonEncode(controlJson(revision: 2, disabled: ['uc']));
      expect(await control.refresh(force: true), ControlRefreshResult.success);
      expect(control.cloudEnabled(CloudPlatform.uc), isFalse);
      fetcher.text = jsonEncode(controlJson(revision: 4, disabled: ['uc']));
      await control.refresh(force: true);
      expect(control.cloudEnabled(CloudPlatform.uc), isFalse);
    },
  );

  test(
    'Week mute and ignored updates survive restart; ID-only changes keep the mute',
    () async {
      fetcher.text = jsonEncode(
        controlJson(noticeId: 'a', androidBuild: 45, windowsBuild: 55),
      );
      await control.refresh(force: true);
      await control.dismissAnnouncement(
        control.config.announcement!,
        hideForWeek: true,
      );
      await control.ignoreUpdate(45);
      final reopened = RemoteControlService(
        store,
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        fetcher: fetcher,
        clock: () => now,
      );
      final windows = RemoteControlService(
        store,
        enabled: true,
        platform: 'windows',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => now,
      );
      addTearDown(reopened.close);
      addTearDown(windows.close);
      expect(reopened.unreadAnnouncement, isNull);
      expect(reopened.unreadUpdate, isNull);
      expect(reopened.availableUpdate!.build, 45);
      expect(windows.unreadUpdate!.build, 55);
      fetcher.text = jsonEncode(
        controlJson(revision: 2, noticeId: 'b', androidBuild: 46),
      );
      await reopened.refresh(force: true);
      expect(reopened.unreadAnnouncement, isNull);
      expect(reopened.unreadUpdate!.build, 46);
      now = now.add(const Duration(days: 1));
      expect(reopened.unreadAnnouncement, isNull);
      now = now.add(const Duration(days: 6));
      expect(reopened.unreadAnnouncement!.id, 'b');
    },
  );

  test(
    'Closing an ordinary update only suppresses this run, including browser round trips',
    () async {
      fetcher.text = jsonEncode(controlJson(androidBuild: 50));
      await control.refresh(force: true);
      await control.dismissUpdate(50);
      expect(control.unreadUpdate, isNull);
      expect(control.availableUpdate!.build, 50);
      expect(
        store.data.obj(RemoteControlService.seenKey)['ignoredUpdates'],
        isNull,
      );
      control.setForeground(false);
      control.setForeground(true);
      await control.refresh(force: true);
      expect(control.unreadUpdate, isNull);
      final reopened = RemoteControlService(
        StateStore.memory(jsonDecode(jsonEncode(store.data))),
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => now,
      );
      addTearDown(reopened.close);
      expect(reopened.unreadUpdate!.build, 50);
      fetcher.text = jsonEncode(controlJson(revision: 2, androidBuild: 51));
      await control.refresh(force: true);
      expect(control.unreadUpdate!.build, 51);
    },
  );

  test(
    'Only a newer build resumes reminders after an explicit ignore',
    () async {
      fetcher.text = jsonEncode(controlJson(androidBuild: 50));
      await control.refresh(force: true);
      await control.ignoreUpdate(50);
      for (final (revision, build) in [(2, 50), (3, 49), (4, 51)]) {
        fetcher.text = jsonEncode(
          controlJson(revision: revision, androidBuild: build),
        );
        await control.refresh(force: true);
        expect(control.unreadUpdate?.build, build > 50 ? 51 : null);
        expect(control.availableUpdate!.build, build);
      }
    },
  );

  test(
    'Forced updates override ignore and session dismissal, and cannot themselves be ignored',
    () async {
      fetcher.text = jsonEncode(controlJson(androidBuild: 50));
      await control.refresh(force: true);
      await control.dismissUpdate(50);
      await control.ignoreUpdate(50);
      fetcher.text = jsonEncode(
        controlJson(revision: 2, androidBuild: 50, force: true),
      );
      await control.refresh(force: true);
      expect(control.requiredUpdate!.build, 50);
      expect(control.unreadUpdate!.force, isTrue);
      final seen = jsonEncode(store.data.obj(RemoteControlService.seenKey));
      await control.dismissUpdate(50);
      await control.ignoreUpdate(50);
      expect(control.unreadUpdate, isNotNull);
      expect(jsonEncode(store.data.obj(RemoteControlService.seenKey)), seen);
      final reopened = RemoteControlService(
        StateStore.memory(jsonDecode(jsonEncode(store.data))),
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => now,
      );
      addTearDown(reopened.close);
      expect(reopened.requiredUpdate!.force, isTrue);
      expect(reopened.unreadUpdate, isNotNull);
      fetcher.text = jsonEncode(
        controlJson(revision: 3, androidBuild: 51, force: true),
      );
      await control.refresh(force: true);
      await control.ignoreUpdate(51);
      expect(control.unreadUpdate!.build, 51);
      expect(jsonEncode(store.data.obj(RemoteControlService.seenKey)), seen);
      fetcher.text = jsonEncode(controlJson(revision: 4));
      await control.refresh(force: true);
      expect(control.requiredUpdate, isNull);
    },
  );

  test(
    'Legacy permanent read IDs and seen updates are not migrated into mutes',
    () {
      final oldState = StateStore.memory({
        ...controlCache(controlJson(noticeId: 'a', androidBuild: 50)),
        RemoteControlService.seenKey: {
          'endpoint': controlEndpoint,
          'announcements': ['a'],
          'updates': ['android:50'],
        },
      });
      final migrated = RemoteControlService(
        oldState,
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => now,
      );
      addTearDown(migrated.close);
      expect(migrated.unreadAnnouncement!.id, 'a');
      expect(migrated.unreadUpdate!.build, 50);
    },
  );

  test('Closing a notice only suppresses the current run and date', () async {
    fetcher.text = jsonEncode(controlJson(noticeId: 'a'));
    await control.refresh(force: true);
    await control.dismissAnnouncement(control.config.announcement!);
    expect(control.unreadAnnouncement, isNull);
    expect(control.announcementMuted, isFalse);
    expect(
      store.data.obj(RemoteControlService.seenKey)['announcementMute'],
      isNull,
    );
    control.setForeground(false);
    control.setForeground(true);
    await control.refresh(force: true);
    expect(control.unreadAnnouncement, isNull);
    final restarted = RemoteControlService(
      StateStore.memory(jsonDecode(jsonEncode(store.data))),
      enabled: true,
      platform: 'android',
      currentBuild: 44,
      configUrl: controlEndpoint,
      clock: () => now,
    );
    addTearDown(restarted.close);
    expect(restarted.unreadAnnouncement, isNotNull);
    now = now.add(const Duration(days: 1));
    expect(control.unreadAnnouncement, isNotNull);
  });

  test(
    'Notice content, rather than its ID or unrelated revision, identifies a session dismissal',
    () async {
      fetcher.text = jsonEncode(controlJson(noticeId: 'a'));
      await control.refresh(force: true);
      await control.dismissAnnouncement(control.config.announcement!);
      fetcher.text = jsonEncode(
        controlJson(revision: 2, noticeId: 'another-id', help: true),
      );
      await control.refresh(force: true);
      expect(control.unreadAnnouncement, isNull);
      final changed = controlJson(revision: 3, noticeId: 'another-id');
      (changed['announcement'] as Map)['content'] = '一条新的公告内容';
      fetcher.text = jsonEncode(changed);
      await control.refresh(force: true);
      expect(control.unreadAnnouncement!.content, '一条新的公告内容');
      await control.dismissAnnouncement(
        control.config.announcement!,
        hideForWeek: true,
      );
      final newer = controlJson(revision: 4, noticeId: 'third');
      (newer['announcement'] as Map)['content'] = '公告内容更新后重新显示';
      fetcher.text = jsonEncode(newer);
      await control.refresh(force: true);
      expect(control.unreadAnnouncement!.content, '公告内容更新后重新显示');
      expect(control.announcementMuted, isFalse);
    },
  );

  test(
    'Week mute lasts exactly seven days across midnight, restart and UTC clocks',
    () async {
      now = DateTime(2026, 12, 31, 23, 59, 59);
      fetcher.text = jsonEncode(controlJson(noticeId: 'a'));
      await control.refresh(force: true);
      await control.dismissAnnouncement(
        control.config.announcement!,
        hideForWeek: true,
      );
      final deadline = now.add(const Duration(days: 7));
      expect(store.data.obj(RemoteControlService.seenKey)['announcementMute'], {
        'contentKey': control.config.announcement!.contentKey,
        'until': deadline.millisecondsSinceEpoch,
      });
      final reopened = RemoteControlService(
        StateStore.memory(jsonDecode(jsonEncode(store.data))),
        enabled: true,
        platform: 'windows',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => now.toUtc(),
      );
      addTearDown(reopened.close);
      expect(reopened.announcementMuted, isTrue);
      expect(reopened.unreadAnnouncement, isNull);
      now = DateTime(2027, 1, 1);
      expect(control.unreadAnnouncement, isNull);
      expect(reopened.unreadAnnouncement, isNull);
      now = deadline.subtract(const Duration(milliseconds: 1));
      expect(control.announcementMuted, isTrue);
      expect(reopened.unreadAnnouncement, isNull);
      now = deadline;
      expect(control.announcementMuted, isFalse);
      expect(control.unreadAnnouncement, isNotNull);
      expect(reopened.unreadAnnouncement, isNotNull);
    },
  );

  for (final field in ['title', 'content', 'buttonText', 'buttonUrl']) {
    test(
      'Changing $field bypasses a saved week mute with the same ID and revision',
      () async {
        final document = controlJson(
          noticeId: 'a',
          buttonText: '查看详情',
          buttonUrl: 'https://example.test/notice',
        );
        fetcher.text = jsonEncode(document);
        await control.refresh(force: true);
        await control.dismissAnnouncement(
          control.config.announcement!,
          hideForWeek: true,
        );
        final reopened = RemoteControlService(
          StateStore.memory(jsonDecode(jsonEncode(store.data))),
          enabled: true,
          platform: 'android',
          currentBuild: 44,
          configUrl: controlEndpoint,
          fetcher: fetcher,
          clock: () => now,
        );
        addTearDown(reopened.close);
        expect(reopened.unreadAnnouncement, isNull);
        (document['announcement'] as Map)[field] = field == 'buttonUrl'
            ? 'https://example.test/new-notice'
            : '更新后的公告';
        fetcher.text = jsonEncode(document);
        await reopened.refresh(force: true);
        expect(reopened.unreadAnnouncement, isNotNull);
        expect(reopened.announcementMuted, isFalse);
      },
    );
  }

  test(
    'Week mute belongs to the endpoint and ignores expired, legacy or malformed values',
    () async {
      fetcher.text = jsonEncode(controlJson(noticeId: 'a'));
      await control.refresh(force: true);
      final key = control.config.announcement!.contentKey;
      final stamp = now.millisecondsSinceEpoch;
      final validUntil = now
          .add(const Duration(days: 7))
          .millisecondsSinceEpoch;
      for (final muted in [
        {'contentKey': key, 'until': stamp - 1},
        {'contentKey': key, 'until': stamp},
        {'contentKey': key, 'until': validUntil + 1},
        {'contentKey': key, 'until': '$validUntil'},
        {'contentKey': key, 'until': true},
        {'contentKey': key, 'until': 999999999999999999},
        {'contentKey': 'invalid', 'until': validUntil},
        {'contentKey': 123, 'until': validUntil},
        {'until': validUntil},
        {'contentKey': key},
        '2026-09-19',
        true,
        null,
        [],
      ]) {
        final reopened = RemoteControlService(
          StateStore.memory({
            ...controlCache(controlJson(noticeId: 'a')),
            RemoteControlService.seenKey: {
              'endpoint': controlEndpoint,
              'announcementMute': muted,
              'announcementMutedDate': '2026-09-19',
            },
          }),
          enabled: true,
          platform: 'android',
          currentBuild: 44,
          configUrl: controlEndpoint,
          clock: () => now,
        );
        expect(reopened.unreadAnnouncement, isNotNull, reason: '$muted');
        reopened.close();
      }
      final reopened = RemoteControlService(
        StateStore.memory({
          ...controlCache(controlJson(noticeId: 'a')),
          RemoteControlService.seenKey: {
            'endpoint': 'https://other.example.test/control.json',
            'announcementMute': {'contentKey': key, 'until': validUntil},
          },
        }),
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => now,
      );
      expect(reopened.unreadAnnouncement, isNotNull);
      reopened.close();
    },
  );

  test(
    'A manual uncheck clears the saved mute without immediately reopening the notice',
    () async {
      fetcher.text = jsonEncode(controlJson(noticeId: 'a', androidBuild: 50));
      await control.refresh(force: true);
      await control.ignoreUpdate(50);
      await control.dismissAnnouncement(
        control.config.announcement!,
        hideForWeek: true,
      );
      await control.dismissAnnouncement(control.config.announcement!);
      expect(control.announcementMuted, isFalse);
      expect(control.unreadAnnouncement, isNull);
      expect(control.unreadUpdate, isNull);
      final reopened = RemoteControlService(
        StateStore.memory(jsonDecode(jsonEncode(store.data))),
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => now,
      );
      addTearDown(reopened.close);
      expect(reopened.unreadAnnouncement, isNotNull);
      expect(reopened.unreadUpdate, isNull);
    },
  );

  testWidgets(
    'Foreground observers are notified at the seven-day deadline during the day',
    (tester) async {
      control.close();
      now = DateTime(2026, 9, 19, 12, 34, 56);
      final state = StateStore.memory(
        controlCache(controlJson(noticeId: 'a'), fetched: now),
      );
      control = RemoteControlService(
        state,
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        fetcher: FakeControlFetcher(controlJson(noticeId: 'a')),
        clock: () => now,
      );
      control.setForeground(true);
      await tester.pump();
      final dismissed = control.dismissAnnouncement(
        control.config.announcement!,
        hideForWeek: true,
      );
      await tester.pump();
      await dismissed;
      expect(control.unreadAnnouncement, isNull);
      control.setForeground(false);
      now = now.add(const Duration(days: 7, seconds: -1));
      control.setForeground(true);
      await tester.pump();
      expect(control.unreadAnnouncement, isNull);
      var notifications = 0;
      control.addListener(() => notifications++);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(notifications, greaterThan(0));
      expect(control.unreadAnnouncement, isNotNull);
      control.close();
    },
  );

  test(
    'Ignore choices are isolated by endpoint and reject malformed builds',
    () {
      for (final ignored in [
        {
          'endpoint': 'https://other.example.test/control.json',
          'ignoredUpdates': {'android': 50},
        },
        {
          'endpoint': controlEndpoint,
          'ignoredUpdates': {'android': '50'},
        },
        {
          'endpoint': controlEndpoint,
          'ignoredUpdates': {'android': -1},
        },
        {
          'endpoint': controlEndpoint,
          'ignoredUpdates': {'android': 2147483648},
        },
      ]) {
        final reopened = RemoteControlService(
          StateStore.memory({
            ...controlCache(controlJson(androidBuild: 50)),
            RemoteControlService.seenKey: ignored,
          }),
          enabled: true,
          platform: 'android',
          currentBuild: 44,
          configUrl: controlEndpoint,
          clock: () => now,
        );
        expect(reopened.unreadUpdate!.build, 50);
        reopened.close();
      }
    },
  );

  test(
    'Changing force or announcement links applies with the same revision',
    () async {
      fetcher.text = jsonEncode(controlJson(noticeId: 'a', androidBuild: 50));
      await control.refresh(force: true);
      for (final changed in [
        controlJson(noticeId: 'a', androidBuild: 50, force: true),
        controlJson(
          noticeId: 'a',
          androidBuild: 50,
          buttonText: '查看详情',
          buttonUrl: 'https://notice.example.test/event',
        ),
      ]) {
        fetcher.text = jsonEncode(changed);
        expect(
          await control.refresh(force: true),
          ControlRefreshResult.success,
        );
        expect(
          control.requiredUpdate != null,
          changed['updates']['android']['force'] == true,
        );
        expect(
          control.config.announcement!.buttonUrl?.toString(),
          changed['announcement']['buttonUrl'],
        );
      }
      fetcher.text = jsonEncode(
        controlJson(
          revision: 2,
          androidBuild: 50,
          noticeId: 'a',
          force: true,
          buttonText: '查看详情',
          buttonUrl: 'https://notice.example.test/event',
        ),
      );
      expect(await control.refresh(force: true), ControlRefreshResult.success);
      expect(control.requiredUpdate, isNotNull);
      expect(control.config.announcement!.buttonUrl, isNotNull);
    },
  );

  test(
    'Update comparison uses the platform build integer, never a version string',
    () async {
      fetcher.text = jsonEncode(
        controlJson(androidBuild: 44, windowsBuild: 90),
      );
      await control.refresh(force: true);
      expect(control.availableUpdate, isNull);
      fetcher.text = jsonEncode(controlJson(revision: 2, androidBuild: 43));
      await control.refresh(force: true);
      expect(control.availableUpdate, isNull);
      fetcher.text = jsonEncode(controlJson(revision: 3, androidBuild: 45));
      await control.refresh(force: true);
      expect(control.availableUpdate!.build, 45);
    },
  );

  testWidgets(
    'Automatic polling pauses in background and coalesces rapid foreground changes',
    (tester) async {
      // Keep the StateStore gate and its futures in the widget test's clock zone.
      control.close();
      fetcher = FakeControlFetcher();
      control = RemoteControlService(
        StateStore.memory(),
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        fetcher: fetcher,
        clock: () => now,
      );
      control.setForeground(true);
      await tester.pump();
      expect(fetcher.calls, hasLength(1));
      expect(control.checking, isFalse);
      control.setForeground(false);
      now = now.add(const Duration(hours: 2));
      await tester.pump(const Duration(hours: 2));
      expect(fetcher.calls, hasLength(1));
      control.setForeground(true);
      control.setForeground(true);
      await tester.pump();
      expect(fetcher.calls, hasLength(2));
      now = now.add(const Duration(minutes: 14));
      await tester.pump(const Duration(minutes: 14));
      expect(fetcher.calls, hasLength(2));
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(fetcher.calls, hasLength(3));
      control.close();
    },
  );

  test(
    'Closing cancels the transport and ignores late responses and notifications',
    () async {
      final response = Completer<String>();
      fetcher.respond = (_) => response.future;
      var notifications = 0;
      control.addListener(() => notifications++);
      final pending = control.refresh(force: true);
      control.close();
      final afterClose = notifications;
      response.complete(jsonEncode(controlJson(disabled: ['uc'])));
      expect(await pending, ControlRefreshResult.closed);
      expect(fetcher.closed, isTrue);
      expect(store.data.containsKey(RemoteControlService.cacheKey), isFalse);
      expect(notifications, afterClose);
      expect(await control.refresh(force: true), ControlRefreshResult.closed);
    },
  );

  test(
    'Corrupt and future-dated cache are ignored without affecting accounts',
    () {
      for (final cache in [
        controlCache({'announcement': []}),
        controlCache(
          controlJson(disabled: ['uc']),
          fetched: now.add(const Duration(days: 1)),
        ),
      ]) {
        final state = StateStore.memory({
          ...cache,
          'credentials': {'fixture': 'preserved'},
        });
        final reopened = RemoteControlService(
          state,
          enabled: true,
          platform: 'android',
          currentBuild: 44,
          configUrl: controlEndpoint,
          clock: () => now,
        );
        expect(reopened.cloudEnabled(CloudPlatform.uc), isTrue);
        expect(state.data['credentials'], {'fixture': 'preserved'});
        reopened.close();
      }
    },
  );
}
