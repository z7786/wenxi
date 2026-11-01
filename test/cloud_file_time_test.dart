import 'package:asterlink/data/providers/personal_cloud.dart';
import 'package:asterlink/domain/cloud_file_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Unix units and ISO time zones resolve to the same local time', () {
    final instant = DateTime.utc(2026, 10, 4, 7, 8, 9);
    for (final raw in [
      '${instant.millisecondsSinceEpoch ~/ 1000}',
      '${instant.millisecondsSinceEpoch}',
      '${instant.microsecondsSinceEpoch}',
      instant.toIso8601String(),
      '2026-10-04T15:08:09+08:00',
      '2026-10-04T15:08:09+0800',
    ]) {
      expect(cloudFileDate(raw), instant.toLocal(), reason: raw);
      expect(
        formatCloudFileTime(raw),
        formatCloudFileTime(instant.toLocal().toIso8601String()),
        reason: raw,
      );
    }
  });

  test('Local and compact dates retain their available precision', () {
    for (final raw in [
      '20261004070809',
      '2026/10/4 7:08:09',
      '2026-10-04 07:08:09',
    ]) {
      expect(cloudFileDate(raw), DateTime(2026, 10, 4, 7, 8, 9));
      expect(formatCloudFileTime(raw), '2026-10-04 07:08');
    }
    for (final raw in ['20261004', '2026/10/4', '2026-10-04']) {
      expect(cloudFileDate(raw), DateTime(2026, 10, 4));
      expect(formatCloudFileTime(raw), '2026-10-04');
    }
    expect(cloudFileDate('2024-02-29'), DateTime(2024, 2, 29));
  });

  test('ISO zones and local dates retain subsecond precision for sorting', () {
    final instant = DateTime.utc(2026, 10, 4, 7, 8, 9, 123, 456);
    for (final raw in [
      instant.toIso8601String(),
      instant.toLocal().toIso8601String(),
      '2026-10-04T15:08:09.123456+08:00',
      '2026-10-04T15:08:09.123456+0800',
      '2026-10-04T07:08:09.123456789Z',
    ]) {
      expect(cloudFileDate(raw), instant.toLocal(), reason: raw);
    }
    expect(
      cloudFileDate('2026/10/4 7:08:09.1'),
      DateTime(2026, 10, 4, 7, 8, 9, 100),
    );
    expect(
      cloudFileDate('2026-10-04 07:08:09.999999'),
      DateTime(2026, 10, 4, 7, 8, 9, 999, 999),
    );
  });

  test(
    'Unix seconds, milliseconds and microseconds retain exact precision',
    () {
      final second = DateTime.utc(2026, 10, 4, 7, 8, 9);
      final instant = second.add(const Duration(microseconds: 123456));
      for (final raw in [
        '${second.millisecondsSinceEpoch ~/ 1000}.123456',
        '${second.millisecondsSinceEpoch + 123}.456',
        '${instant.microsecondsSinceEpoch}',
      ]) {
        expect(cloudFileDate(raw), instant.toLocal(), reason: raw);
      }
      expect(
        cloudFileDate('${second.millisecondsSinceEpoch ~/ 1000}.999999'),
        second.add(const Duration(microseconds: 999999)).toLocal(),
      );
    },
  );

  test('Missing and corrupt timestamps never display an invented date', () {
    for (final raw in [
      '',
      '   ',
      '0',
      '-1',
      'null',
      'not a date',
      '2026-02-30',
      '20260230070809',
      '2026-13-01',
      '2026-10-04 25:00',
      '2026-10-04T07:08:09+25:00',
      '999999999999999999999999',
    ]) {
      expect(cloudFileDate(raw), isNull, reason: raw);
      expect(formatCloudFileTime(raw), isEmpty, reason: raw);
    }
    for (final raw in ['刚刚', '昨天 12:30', '3天前', '2 小时前']) {
      expect(cloudFileDate(raw), isNull);
      expect(formatCloudFileTime(raw), raw);
    }
  });

  test(
    'Personal providers handle Unix seconds without producing 1970 dates',
    () {
      final instant = DateTime(2026, 10, 4, 7, 8, 9);
      expect(
        personalCloudDate('${instant.millisecondsSinceEpoch ~/ 1000}'),
        '2026-10-04 07:08:09',
      );
      expect(
        personalCloudDate('${instant.millisecondsSinceEpoch}'),
        '2026-10-04 07:08:09',
      );
      expect(personalCloudDate('20261004070809'), '2026-10-04 07:08:09');
      expect(personalCloudDate('20261004'), '2026-10-04');
      expect(personalCloudDate('2026-10-04'), '2026-10-04');
      expect(personalCloudDate('昨天'), '昨天');
      expect(personalCloudDate('0'), '0');
    },
  );

  test(
    'Relative sort keys use one local reference and retain display labels',
    () {
      final reference = DateTime(2026, 10, 29, 15, 40, 30);
      final times = {
        '刚刚': reference,
        '今天': DateTime(2026, 10, 29),
        '今天06:17': DateTime(2026, 10, 29, 6, 17),
        '昨天 12:30': DateTime(2026, 10, 28, 12, 30),
        '昨天12:30': DateTime(2026, 10, 28, 12, 30),
        '前天': DateTime(2026, 10, 27),
        '前天06:17': DateTime(2026, 10, 27, 6, 17),
        '前天06:16': DateTime(2026, 10, 27, 6, 16),
        '30秒前': DateTime(2026, 10, 29, 15, 40),
        '5 分钟前': DateTime(2026, 10, 29, 15, 35, 30),
        '2小时前': DateTime(2026, 10, 29, 13, 40, 30),
        '3 天前': DateTime(2026, 10, 26),
        '3天前 9:08': DateTime(2026, 10, 26, 9, 8),
        '3天前9:08': DateTime(2026, 10, 26, 9, 8),
        '2周前': DateTime(2026, 10, 15),
        '1个月前': DateTime(2026, 9, 29),
        '2月前': DateTime(2026, 8, 29),
        '1年前': DateTime(2025, 10, 29),
      };
      for (final entry in times.entries) {
        expect(
          cloudFileSortDate(entry.key, reference: reference.toUtc()),
          entry.value,
          reason: entry.key,
        );
        expect(formatCloudFileTime(entry.key), entry.key);
        expect(cloudFileDate(entry.key), isNull);
      }
      expect(
        cloudFileSortDate('2026-10-04 07:08:09.123456', reference: reference),
        DateTime(2026, 10, 4, 7, 8, 9, 123, 456),
      );
    },
  );

  test('Relative calendar dates handle month and leap year boundaries', () {
    expect(
      cloudFileSortDate('昨天 23:30', reference: DateTime(2026, 1, 1, 1)),
      DateTime(2025, 12, 31, 23, 30),
    );
    expect(
      cloudFileSortDate('1个月前', reference: DateTime(2026, 3, 31)),
      DateTime(2026, 2, 28),
    );
    expect(
      cloudFileSortDate('1年前', reference: DateTime(2024, 2, 29)),
      DateTime(2023, 2, 28),
    );
  });

  test('Invalid relative dates remain undated for sorting', () {
    final reference = DateTime(2026, 10, 29);
    for (final raw in [
      '',
      'not a date',
      '昨天 25:00',
      '前天25:00',
      '前天06:60',
      '3天前 12:60',
      '-1天前',
      '999999999999999999999999秒前',
      '999999999天前',
      '999999999个月前',
      '999999999年前',
      '60年前',
    ]) {
      expect(cloudFileSortDate(raw, reference: reference), isNull, reason: raw);
    }
    expect(cloudFileSortDate('昨天', reference: DateTime(1970)), isNull);
  });

  test(
    'Personal providers keep timestamp precision before browser sorting',
    () {
      final instant = DateTime(2026, 10, 4, 7, 8, 9, 123, 456);
      for (final raw in [
        '${instant.microsecondsSinceEpoch}',
        '${instant.millisecondsSinceEpoch}.456',
        '${instant.millisecondsSinceEpoch ~/ 1000}.123456',
      ]) {
        final converted = personalCloudDate(raw);
        expect(converted, '2026-10-04 07:08:09.123456', reason: raw);
        expect(cloudFileDate(converted), instant, reason: raw);
        expect(formatCloudFileTime(converted), '2026-10-04 07:08');
      }
    },
  );
}
