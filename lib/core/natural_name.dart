import 'package:pinyin/pinyin.dart';

/// A case-insensitive name whose numeric segments compare by value.
/// Chinese text compares by untoned pinyin, including common polyphonic phrases.
/// Equal numbers, including zero-padded ones, leave tie-breaking to the caller.
class NaturalName implements Comparable<NaturalName> {
  NaturalName(String name) : _parts = _split(name);

  final List<(String, BigInt?)> _parts;

  @override
  int compareTo(NaturalName other) {
    final a = _parts, b = other._parts;
    for (var i = 0; i < a.length && i < b.length; i++) {
      final (textA, numberA) = a[i];
      final (textB, numberB) = b[i];
      final result = numberA != null && numberB != null
          ? numberA.compareTo(numberB)
          : textA.compareTo(textB);
      if (result != 0) return result;
    }
    return a.length.compareTo(b.length);
  }
}

List<(String, BigInt?)> _split(String name) {
  final normalized = _pinyinKey(
    name.toLowerCase().replaceAllMapped(
      RegExp(r'第\s*([零〇一二两三四五六七八九十百千]+)\s*([集话章期部季])'),
      (match) => '第${_chineseNumber(match[1]!)}${match[2]}',
    ),
  );
  return RegExp(r'\d+|\D+').allMatches(normalized).map((match) {
    final text = match[0]!;
    return (text, BigInt.tryParse(text));
  }).toList();
}

String _pinyinKey(String name) {
  if (!name.runes.any(ChineseHelper.isChineseCode)) return name;
  final result = StringBuffer(), chinese = StringBuffer();
  void flush() {
    if (chinese.isEmpty) return;
    result.write(
      PinyinHelper.getPinyin(
        chinese.toString(),
        separator: '',
        format: PinyinFormat.WITHOUT_TONE,
      ),
    );
    chinese.clear();
  }

  for (final rune in name.runes) {
    final char = String.fromCharCode(rune);
    // Convert known Chinese runs together so phrase pronunciations survive.
    // Keep unknown ideographs and all non-Chinese text unchanged in the key.
    if (ChineseHelper.isChineseCode(rune) &&
        PinyinHelper.pinyinMap.containsKey(char)) {
      chinese.write(char);
    } else {
      flush();
      result.write(char);
    }
  }
  flush();
  return result.toString();
}

int _chineseNumber(String value) {
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000};
  var total = 0, digit = 0;
  for (final char in value.split('')) {
    final unit = units[char];
    if (unit == null) {
      digit = digit * 10 + (digits[char] ?? 0);
    } else {
      total += (digit == 0 ? 1 : digit) * unit;
      digit = 0;
    }
  }
  return total + digit;
}
