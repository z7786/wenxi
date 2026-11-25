import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'remote_control_support.dart';

Map<String, Object?> noticeJson() => {
  'enabled': true,
  'title': '搜索首页公告',
  'content': '支持 **Markdown** 正文',
  'startsAt': '2026-09-19T04:00:10Z',
  'expiresAt': '2026-09-19T04:00:20Z',
  'buttonText': '查看详情',
  'buttonUrl': 'https://example.test/news',
};

void main() {
  test(
    'Search notice roundtrips, has optional body and inclusive start/exclusive end',
    () {
      final config = RemoteControlConfig.fromJson({
        'searchAnnouncement': noticeJson(),
      });
      final notice = RemoteControlConfig.fromJson(
        config.toJson(),
      ).searchAnnouncement!;
      expect(notice.content, '支持 **Markdown** 正文');
      expect(notice.buttonUrl!.host, 'example.test');
      expect(
        notice.isActive(
          notice.startsAt!.subtract(const Duration(microseconds: 1)),
        ),
        isFalse,
      );
      expect(notice.isActive(notice.startsAt!), isTrue);
      expect(notice.isActive(notice.expiresAt!), isFalse);
      expect(config.announcement, isNull);
      expect(
        RemoteControlConfig.fromJson(<String, dynamic>{}).searchAnnouncement,
        isNull,
      );
      expect(
        RemoteControlConfig.fromJson({
          'searchAnnouncement': {'enabled': true, 'title': '简短通知'},
        }).searchAnnouncement!.content,
        isEmpty,
      );
    },
  );

  test(
    'Invalid notice retains its previous section without blocking other config',
    () {
      final previous = RemoteControlConfig.fromJson({
        'searchAnnouncement': noticeJson(),
      });
      for (final (field, value) in <(String, Object)>[
        ('title', ''),
        ('title', '字' * 161),
        ('content', '字' * 8193),
        ('enabled', 'true'),
        ('startsAt', '2026-02-30T00:00:00Z'),
        ('startsAt', '2026-09-19T12:00:00+08:00'),
        ('expiresAt', 3),
        ('expiresAt', '2026-09-19T04:00:10Z'),
        ('buttonUrl', 'javascript:alert(1)'),
        ('buttonText', ''),
      ]) {
        final document = RemoteControlDocument.parse({
          'searchAnnouncement': {...noticeJson(), field: value},
          'about': {'description': '其他配置继续生效'},
        }, previous: previous);
        expect(document.issues.single.path, 'searchAnnouncement.$field');
        expect(
          ControlConfigIssue.isKnownPath(document.issues.single.path),
          isTrue,
        );
        expect(
          document.config.searchAnnouncement,
          same(previous.searchAnnouncement),
        );
        expect(document.config.aboutDescription, '其他配置继续生效');
      }
      for (final raw in <Map<String, dynamic>>[
        {},
        {
          'searchAnnouncement': {'enabled': false, 'title': 3},
        },
      ]) {
        expect(
          RemoteControlDocument.parse(
            raw,
            previous: previous,
          ).validated.searchAnnouncement,
          isNull,
        );
      }
    },
  );

  test(
    'Cached scheduled notice appears and expires without another fetch; resumes correctly',
    () {
      fakeAsync((async) {
        final start = DateTime.utc(2026, 9, 19, 4);
        final source = controlJson(noticeId: 'startup')
          ..['searchAnnouncement'] = noticeJson();
        final store = StateStore.memory();
        final fetcher = FakeControlFetcher(source);
        RemoteControlService service() => RemoteControlService(
          store,
          platform: 'windows',
          currentBuild: 240,
          enabled: true,
          configUrl: controlEndpoint,
          fetcher: fetcher,
          clock: () => start.add(async.elapsed),
        );
        var control = service();
        control.setForeground(true);
        async.flushMicrotasks();
        expect(control.cachePersisted, isTrue);
        expect(control.config.searchAnnouncement, isNull);
        expect(control.unreadAnnouncement, isNotNull);
        control.close();
        // A future notice must survive persisted cache even while it is hidden.
        expect(jsonEncode(store.data), contains('searchAnnouncement'));
        control = service();
        control.setForeground(true);
        async.flushMicrotasks();
        final events = <bool>[];
        control.addListener(
          () => events.add(control.config.searchAnnouncement != null),
        );
        final calls = fetcher.calls.length;
        async.elapse(const Duration(seconds: 10));
        expect(events, [true]);
        expect(fetcher.calls.length, calls);
        control.setForeground(false);
        async.elapse(const Duration(seconds: 10));
        expect(events, [true]);
        control.setForeground(true);
        async.flushMicrotasks();
        expect(events.last, isFalse);
        expect(control.config.searchAnnouncement, isNull);
        expect(control.unreadAnnouncement, isNotNull);
        control.close();
        store.dispose();
      });
    },
  );

  test(
    'Active notice expires on schedule and same revision changes replace it',
    () {
      fakeAsync((async) {
        final start = DateTime.utc(2026, 9, 19, 4, 0, 10);
        final source = {'searchAnnouncement': noticeJson()};
        final store = StateStore.memory();
        final fetcher = FakeControlFetcher(source);
        final control = RemoteControlService(
          store,
          platform: 'android',
          currentBuild: 240,
          configUrl: controlEndpoint,
          enabled: true,
          fetcher: fetcher,
          clock: () => start.add(async.elapsed),
        );
        control.setForeground(true);
        async.flushMicrotasks();
        var changes = 0;
        control.addListener(() => changes++);
        async.elapse(const Duration(seconds: 10));
        expect(changes, 1);
        expect(control.config.searchAnnouncement, isNull);
        fetcher.text = jsonEncode({
          'searchAnnouncement': {'enabled': true, 'title': '新通知'},
        });
        control.refresh(force: true);
        async.flushMicrotasks();
        expect(control.config.searchAnnouncement!.title, '新通知');
        fetcher.text = '{}';
        control.refresh(force: true);
        async.flushMicrotasks();
        expect(control.config.searchAnnouncement, isNull);
        control.close();
        store.dispose();
      });
    },
  );
}
