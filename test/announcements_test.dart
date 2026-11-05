import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/announcements.dart';
import 'announcements_support.dart';

void main() {
  test('Multiple notices sort by pin, date and stable input order', () {
    final fixture = announcementsFixture();
    final rows = fixture['announcements'] as List;
    rows.insert(0, announcementRow('undated'));
    rows.add(announcementRow('undated-last'));
    rows.add({...announcementRow('disabled'), 'enabled': false});
    rows.add(rows[2]);
    final feed = AnnouncementFeed.fromJson(fixture);
    expect(feed.messages.map((item) => item.id), [
      'welcome',
      'new',
      'feedback',
      'undated',
      'undated-last',
    ]);
    expect(feed.skippedItems, 0);
    expect(AnnouncementFeed.fromJson(feed.toJson()).toJson(), feed.toJson());
  });

  test(
    'Displayed content determines unread identity, without IDs or revisions',
    () {
      final row = announcementRow('same');
      AnnouncementMessage parse() => AnnouncementFeed.fromJson({
        'announcements': [row],
        'revision': -100,
      }).messages.single;
      final original = parse().contentKey;
      row.remove('id');
      row['publishedAt'] = '2026-10-10';
      row['pinned'] = true;
      expect(parse().contentKey, original);
      row['title'] = '内容更新';
      expect(parse().contentKey, isNot(original));
    },
  );

  test(
    'A bad row cannot hide other valid messages or execute an unsafe link',
    () {
      final fixture = announcementsFixture();
      (fixture['announcements'] as List).addAll([
        {'title': 'missing body'},
        {
          ...announcementRow('unsafe'),
          'buttonText': '打开',
          'buttonUrl': 'javascript:alert(1)',
        },
        {...announcementRow('bad-date'), 'publishedAt': '2026-02-30T00:00:00Z'},
        {...announcementRow('bad-time'), 'publishedAt': '2026-10-10T27:00:00Z'},
        {
          ...announcementRow('bad-zone'),
          'publishedAt': '2026-10-10T08:00:00+99:99',
        },
        {...announcementRow('button'), 'buttonText': '没有地址'},
      ]);
      final feed = AnnouncementFeed.fromJson(fixture);
      expect(feed.messages, hasLength(3));
      expect(feed.skippedItems, 6);
      expect(feed.messages.last.buttonUrl!.scheme, 'https');
    },
  );

  test(
    'Malformed publications are rejected, intentional empty lists are accepted',
    () {
      for (final source in [
        null,
        [],
        {},
        {'announcements': 'wrong'},
        {
          'announcements': [null],
        },
        {
          'announcements': [
            {'title': 'missing body'},
          ],
        },
        {'announcements': List.generate(101, (i) => announcementRow('$i'))},
      ]) {
        expect(() => AnnouncementFeed.fromJson(source), throwsFormatException);
      }
      expect(
        AnnouncementFeed.fromJson({'announcements': []}).messages,
        isEmpty,
      );
      expect(AnnouncementFeed.fromJson({'enabled': false}).messages, isEmpty);
      expect(
        AnnouncementFeed.fromJson({
          'announcements': [
            {'enabled': false},
          ],
        }).messages,
        isEmpty,
      );
      expect(() => AnnouncementFeed.decode('{'), throwsFormatException);
      expect(
        AnnouncementFeed.decode('\uFEFF{"announcements":[]}').messages,
        isEmpty,
      );
      expect(
        () => AnnouncementFeed.decode(
          jsonEncode({'padding': '中' * 90000, 'announcements': []}),
        ),
        throwsFormatException,
      );
    },
  );

  test('Multiline and HTML-looking content remain ordinary text', () {
    const body = '<script>alert(1)</script>\n第二行';
    final feed = AnnouncementFeed.fromJson({
      'announcements': [
        {'title': '普通文字', 'content': body},
      ],
    });
    expect(feed.messages.single.content, body);
    expect(feed.messages.single.buttonUrl, isNull);
  });

  test('Public JSON example contains multiple valid notices', () {
    final feed = AnnouncementFeed.decode(
      File('config/announcements.example.json').readAsStringSync(),
    );
    expect(feed.messages.length, greaterThanOrEqualTo(2));
    expect(feed.skippedItems, 0);
  });

  test('Pictures and mini-program buttons survive cache serialization', () {
    final source = {
      'announcements': [
        {
          ...announcementRow('mini-program'),
          'content': '活动详情\n\n![活动图片](https://images.example.test/notice.png)',
          'buttonText': '打开微信小程序',
          'buttonUrl': 'weixin://dl/business/?t=example-ticket',
        },
      ],
    };
    final feed = AnnouncementFeed.fromJson(source);
    final message = feed.messages.single;
    final restored = AnnouncementFeed.fromJson(feed.toJson()).messages.single;
    expect(restored.content, message.content);
    expect(restored.buttonUrl, message.buttonUrl);
    expect(restored.contentKey, message.contentKey);
  });
}
