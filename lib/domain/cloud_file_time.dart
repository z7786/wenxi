// Providers return local dates, ISO dates, compact dates, or Unix timestamps.
DateTime? cloudFileDate(String value) {
  final raw = value.trim();
  if (raw.isEmpty || raw.length > 64) return null;
  final compact = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(?:(\d{2})(\d{2})(\d{2}))?$',
  ).firstMatch(raw);
  if (compact != null) {
    final year = int.parse(compact[1]!);
    if (year >= 1970 && year <= 9999) {
      return _calendarDate(
        year,
        int.parse(compact[2]!),
        int.parse(compact[3]!),
        int.parse(compact[4] ?? '0'),
        int.parse(compact[5] ?? '0'),
        int.parse(compact[6] ?? '0'),
      );
    }
  }
  final numeric = RegExp(r'^(-?\d+)(?:\.(\d+))?$').firstMatch(raw);
  if (numeric != null) {
    final whole = int.tryParse(numeric[1]!);
    if (whole == null || raw.startsWith('-')) return null;
    final scale = whole < 100000000000
        ? 1000000
        : whole >= 100000000000000
        ? 1
        : 1000;
    // Bound corrupt values before multiplication and avoid floating-point
    // rounding, which can change the order of files modified in one second.
    const maximum = 253402214400000000;
    if (whole > maximum ~/ scale) return null;
    final fraction = scale == 1
        ? 0
        : _fractionalUnits(numeric[2] ?? '', scale == 1000000 ? 6 : 3);
    final microseconds = whole * scale + fraction;
    if (microseconds <= 0 || microseconds > maximum) return null;
    return DateTime.fromMicrosecondsSinceEpoch(microseconds).toLocal();
  }
  final normalized = raw.replaceAll('/', '-');
  final fields = RegExp(
    r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?(Z|[+-]\d{2}:?\d{2})?$',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (fields == null) return null;
  final year = int.parse(fields[1]!),
      month = int.parse(fields[2]!),
      day = int.parse(fields[3]!);
  final hour = int.parse(fields[4] ?? '0'),
      minute = int.parse(fields[5] ?? '0'),
      second = int.parse(fields[6] ?? '0');
  final local = _calendarDate(year, month, day, hour, minute, second);
  if (local == null) return null;
  final fraction = fields[7] ?? '';
  if (fields[8] == null) {
    return local.add(Duration(microseconds: _fractionalUnits(fraction, 6)));
  }
  final zone = fields[8]!.toUpperCase();
  if (zone != 'Z') {
    final digits = zone.substring(1).replaceAll(':', '');
    if (int.parse(digits.substring(0, 2)) > 23 ||
        int.parse(digits.substring(2)) > 59) {
      return null;
    }
  }
  return DateTime.tryParse(
    '${_date(local)}T${_two(hour)}:${_two(minute)}:${_two(second)}'
    '${fraction.isEmpty ? '' : '.$fraction'}$zone',
  )?.toLocal();
}

// Relative labels provide an approximate sort key; keep their original text
// for display. Use the time the listing was loaded for a stable reference.
DateTime? cloudFileSortDate(String value, {required DateTime reference}) {
  final absolute = cloudFileDate(value);
  if (absolute != null) return absolute;
  final raw = value.trim();
  if (raw.isEmpty || raw.length > 64) return null;
  final fields = RegExp(
    r'^(刚刚|今天|昨天|前天|(\d+)\s*(秒|分钟|小时|天|周|个月|月|年)前)(?:\s*(\d{1,2}):(\d{2}))?$',
  ).firstMatch(raw);
  if (fields == null) return null;
  final local = reference.toLocal();
  final epoch = DateTime(1970);
  if (local.isBefore(epoch) || local.year > 9999) return null;
  final amount = int.tryParse(fields[2] ?? '0');
  if (amount == null) return null;
  final unit = fields[3];
  DateTime date;
  if (unit == null) {
    date = switch (fields[1]) {
      '刚刚' => local,
      '昨天' => DateTime(local.year, local.month, local.day - 1),
      '前天' => DateTime(local.year, local.month, local.day - 2),
      _ => DateTime(local.year, local.month, local.day),
    };
  } else if (unit == '秒' || unit == '分钟' || unit == '小时') {
    final seconds = unit == '小时'
        ? 3600
        : unit == '分钟'
        ? 60
        : 1;
    if (amount > local.difference(epoch).inSeconds ~/ seconds) return null;
    date = local.subtract(Duration(seconds: amount * seconds));
  } else if (unit == '天' || unit == '周') {
    final days = unit == '周' ? 7 : 1;
    if (amount > (local.year - 1969) * 366 ~/ days) return null;
    date = DateTime(local.year, local.month, local.day - amount * days);
  } else {
    final months = unit == '年' ? 12 : 1;
    final available = (local.year - 1970) * 12 + local.month - 1;
    if (amount > available ~/ months) return null;
    final target = local.year * 12 + local.month - 1 - amount * months;
    final year = target ~/ 12, month = target % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    date = DateTime(year, month, local.day > lastDay ? lastDay : local.day);
  }
  if (fields[4] != null) {
    final withTime = _calendarDate(
      date.year,
      date.month,
      date.day,
      int.parse(fields[4]!),
      int.parse(fields[5]!),
      0,
    );
    if (withTime == null) return null;
    date = withTime;
  }
  return date.isBefore(epoch) ? null : date;
}

int _fractionalUnits(String digits, int precision) =>
    int.parse(digits.padRight(precision, '0').substring(0, precision));

DateTime? _calendarDate(
  int year,
  int month,
  int day,
  int hour,
  int minute,
  int second,
) {
  if (year < 1970 ||
      year > 9999 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31 ||
      hour < 0 ||
      hour > 23 ||
      minute < 0 ||
      minute > 59 ||
      second < 0 ||
      second > 59) {
    return null;
  }
  final date = DateTime(year, month, day, hour, minute, second);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

String _two(int value) => '$value'.padLeft(2, '0');
String _date(DateTime date) =>
    '${date.year}-${_two(date.month)}-${_two(date.day)}';

String formatCloudFileTime(String value) {
  final raw = value.trim();
  final date = cloudFileDate(raw);
  if (date != null) {
    if (RegExp(r'^\d{4}[-/]\d{1,2}[-/]\d{1,2}$|^\d{8}$').hasMatch(raw)) {
      return _date(date);
    }
    return '${_date(date)} ${_two(date.hour)}:${_two(date.minute)}';
  }
  // Keep the provider's relative label without inventing an exact timestamp.
  return RegExp(
        r'^(?:刚刚|今天|昨天|前天|\d+\s*(?:秒|分钟|小时|天|周|个月|月|年)前)(?:\s*\d{1,2}:\d{2})?$',
      ).hasMatch(raw)
      ? raw
      : '';
}
