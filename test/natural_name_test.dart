import 'package:asterlink/core/natural_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> sorted(List<String> names, {bool ascending = true}) {
    final keys = {for (final name in names) name: NaturalName(name)};
    return [...names]..sort((a, b) {
      final order = keys[a]!.compareTo(keys[b]!);
      return ascending ? order : -order;
    });
  }

  test('episode names compare the complete number in either direction', () {
    final names = [
      for (final episode in [19, 1, 10, 11, 2, 9, 20, 100]) '第$episode集.mp4',
    ];
    final expected = [
      for (final episode in [1, 2, 9, 10, 11, 19, 20, 100]) '第$episode集.mp4',
    ];
    expect(sorted(names), expected);
    expect(sorted(names, ascending: false), expected.reversed);
  });

  test('season and episode segments compare independently', () {
    expect(sorted(['S02E01.mkv', 'S01E10.mkv', 's01e02.mkv', 'S01E1.mkv']), [
      'S01E1.mkv',
      's01e02.mkv',
      'S01E10.mkv',
      'S02E01.mkv',
    ]);
    expect(NaturalName('S01E1.MKV').compareTo(NaturalName('s1e001.mkv')), 0);
    expect(NaturalName('第1集.mp4').compareTo(NaturalName('第01集.mp4')), 0);
  });

  test('Chinese episode and season numbers follow numeric order', () {
    expect(sorted(['第一百零二集', '第十二集', '第一集', '第十集', '第二集']), [
      '第一集',
      '第二集',
      '第十集',
      '第十二集',
      '第一百零二集',
    ]);
    expect(sorted(['第十季', '第两季', '第一季']), ['第一季', '第两季', '第十季']);
  });

  test('Chinese names follow full pinyin in both directions', () {
    final names = ['资料.txt', '假期.txt', '阿里.txt', '工作.txt', '北京.txt'];
    final expected = ['阿里.txt', '北京.txt', '工作.txt', '假期.txt', '资料.txt'];
    expect(sorted(names), expected);
    expect(sorted(names, ascending: false), expected.reversed);
    expect(sorted(['安宁', '阿姨', '阿波', '安康']), ['阿波', '安康', '安宁', '阿姨']);
  });

  test(
    'Pinyin recognizes common polyphonic phrases and traditional Chinese',
    () {
      for (final (chinese, romanized) in [
        ('重庆02.mp4', 'chongqing2.mp4'),
        ('重慶02.mp4', 'chongqing2.mp4'),
        ('音乐10.mp3', 'yinyue10.mp3'),
        ('音樂10.mp3', 'yinyue10.mp3'),
        ('银行01.pdf', 'yinhang1.pdf'),
      ]) {
        expect(
          NaturalName(chinese).compareTo(NaturalName(romanized)),
          0,
          reason: chinese,
        );
      }
    },
  );

  test(
    'Mixed Chinese and Latin names retain natural numbers and case folding',
    () {
      expect(sorted(['BAOGAO10.txt', '报告02.txt', '报告12.txt', 'baogao1.txt']), [
        'baogao1.txt',
        '报告02.txt',
        'BAOGAO10.txt',
        '报告12.txt',
      ]);
      expect(
        NaturalName('文件第十二集.MKV').compareTo(NaturalName('wenjiandi12ji.mkv')),
        0,
      );
      expect(NaturalName('同01集.mp4').compareTo(NaturalName('童1集.mp4')), 0);
    },
  );

  test(
    'Pinyin preserves punctuation, emoji and unmapped Chinese characters',
    () {
      expect(
        NaturalName(
          '😀重庆-报告2（完）.mkv',
        ).compareTo(NaturalName('😀chongqing-baogao02（wan）.mkv')),
        0,
      );
      expect(
        NaturalName(
          '报告\u{2EE5D}2.txt',
        ).compareTo(NaturalName('baogao\u{2EE5D}02.txt')),
        0,
      );
      expect(
        NaturalName(
          '报告\u{2EE5D}2.txt',
        ).compareTo(NaturalName('报告\u{2EE5C}2.txt')),
        isNot(0),
      );
    },
  );

  test('very long numbers do not overflow and plain names still sort', () {
    final smaller = '9' * 40, larger = '1${'0' * 40}';
    expect(sorted(['part$larger.zip', 'part$smaller.zip']), [
      'part$smaller.zip',
      'part$larger.zip',
    ]);
    expect(sorted(['Bravo.txt', 'alpha.txt', '', 'Charlie.txt']), [
      '',
      'alpha.txt',
      'Bravo.txt',
      'Charlie.txt',
    ]);
  });
}
