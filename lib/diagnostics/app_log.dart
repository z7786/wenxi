import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/app_version.dart';
import 'redaction.dart';

export '../core/app_version.dart' show applicationVersion;

String beijingLogTime(Object? value) {
  final DateTime? parsed;
  if (value is DateTime) {
    parsed = value;
  } else if (value is num) {
    parsed = DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  } else {
    final text = '${value ?? ''}'.trim();
    // Older records without an offset were written in UTC as well.
    parsed = DateTime.tryParse(
      RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(text)
          ? text
          : '${text}Z',
    );
  }
  if (parsed == null) return '时间未记录';
  final time = parsed.toUtc().add(const Duration(hours: 8));
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

class LogEntry {
  LogEntry(this.data);
  final Map<String, dynamic> data;
  String get level => '${data['level'] ?? 'info'}';
  String get event => '${data['event'] ?? ''}';
  String get time => '${data['time'] ?? ''}';
  String get detail => const JsonEncoder.withIndent('  ').convert(data);
  String get displayTime => beijingLogTime(time);
  String get displayDetail => const JsonEncoder.withIndent(
    '  ',
  ).convert({...data, 'time': '$displayTime（北京时间 UTC+08:00）'});
}

/// Best-effort local recorder. No network, account store, or download file is
/// opened here. A full/unwritable disk must never crash the logging caller.
class DiagnosticLog extends ChangeNotifier {
  DiagnosticLog._(
    this.directory,
    this.clock,
    this.maxFileBytes,
    this.maxFiles,
    this.retention,
  ) : session =
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30).toRadixString(16)}';
  static DiagnosticLog? active;
  static const defaultFileBytes = 512 * 1024;
  static const defaultMaxFiles = 8;
  final Directory? directory;
  final DateTime Function() clock;
  final int maxFileBytes, maxFiles;
  final Duration retention;
  final String session;
  final _memory = <String>[];
  final _recent = <String, DateTime>{};
  final _pendingLines = <({DateTime day, List<int> bytes})>[];
  Timer? _flushTimer;
  int _pendingBytes = 0, _currentBytes = 0;
  File? _current;
  DateTime? _fileDay;
  int _part = 0, _sequence = 0, _suppressed = 0;
  bool _enabled = true, _writing = false, _closed = false;
  bool previousSessionInterrupted = false;
  String? storageError;
  bool get enabled => _enabled;
  bool get persisted => directory != null && storageError == null;
  int get suppressed => _suppressed;

  static DiagnosticLog open(
    Directory? directory, {
    DateTime Function()? clock,
    int maxFileBytes = defaultFileBytes,
    int maxFiles = defaultMaxFiles,
    Duration retention = const Duration(days: 7),
    bool? enabled,
  }) {
    if (maxFileBytes < 1024 || maxFiles < 1 || retention <= Duration.zero) {
      throw ArgumentError('Invalid log retention limits');
    }
    final log = DiagnosticLog._(
      directory,
      clock ?? DateTime.now,
      maxFileBytes,
      maxFiles,
      retention,
    );
    try {
      directory?.createSync(recursive: true);
      if (directory != null) {
        log._enabled = !File(p.join(directory.path, 'disabled')).existsSync();
        if (enabled != null) {
          log._enabled = enabled;
          final flag = File(p.join(directory.path, 'disabled'));
          if (enabled) {
            if (flag.existsSync()) flag.deleteSync();
          } else {
            flag.writeAsStringSync('disabled', flush: true);
          }
        }
        log.previousSessionInterrupted = File(
          p.join(directory.path, 'session.json'),
        ).existsSync();
        log._prune();
      }
      log._enabled = enabled ?? log._enabled;
      if (log._enabled) {
        log.lifecycle('starting');
        log.record(
          'session.start',
          fields: {
            'version': applicationVersion,
            'os': Platform.operatingSystem,
            'build': kReleaseMode
                ? 'release'
                : kProfileMode
                ? 'profile'
                : 'debug',
            'previousSessionInterrupted': log.previousSessionInterrupted,
          },
        );
      }
    } catch (_) {
      log.storageError = '无法写入日志目录，本次日志暂存在内存中';
    }
    return log;
  }

  static void event(String name, {Map<String, Object?> fields = const {}}) =>
      active?.record(name, fields: fields);
  static void error(
    String name,
    Object error,
    StackTrace? stack, {
    Map<String, Object?> fields = const {},
    bool fatal = false,
  }) => active?.record(
    name,
    level: fatal ? 'fatal' : 'error',
    error: error,
    stack: stack,
    fields: fields,
  );
  static String reference(String id) =>
      sha256.convert(utf8.encode(id)).toString().substring(0, 12);

  void record(
    String event, {
    String level = 'info',
    Object? error,
    StackTrace? stack,
    Map<String, Object?> fields = const {},
    bool flush = false,
  }) {
    if (!_enabled || _closed || _writing) return;
    _writing = true;
    try {
      final cleanEvent = LogRedactor.text(event, limit: 120);
      level = {'info', 'warning', 'error', 'fatal'}.contains(level)
          ? level
          : 'info';
      final message = error == null
          ? null
          : LogRedactor.text(error, limit: 3500);
      final now = clock().toUtc();
      final fingerprint =
          '$cleanEvent|$level|$message|${LogRedactor.json(fields)}';
      final last = _recent[fingerprint];
      if (level != 'fatal' &&
          last != null &&
          now.difference(last) >= Duration.zero &&
          now.difference(last) < const Duration(seconds: 3)) {
        _suppressed++;
        if (flush || level == 'error') this.flush();
        return;
      }
      _recent[fingerprint] = now;
      while (_recent.length > 64) {
        _recent.remove(_recent.keys.first);
      }
      final entry = <String, Object?>{
        'time': now.toIso8601String(),
        'session': session,
        'seq': ++_sequence,
        'level': level,
        'event': cleanEvent,
        if (error != null)
          'errorType': LogRedactor.text(error.runtimeType, limit: 100),
        'message': ?message,
        if (stack != null) 'stack': LogRedactor.text(stack, limit: 9000),
        if (fields.isNotEmpty) 'fields': LogRedactor.value(fields),
        if (_suppressed > 0) 'suppressedRepeats': _suppressed,
      };
      var line = jsonEncode(entry);
      if (utf8.encode(line).length > 40 * 1024) {
        entry['fields'] = '[诊断字段过长，已截断]';
        line = jsonEncode(entry);
      }
      _memory.add(line);
      while (_memory.length > 100) {
        _memory.removeAt(0);
      }
      if (directory != null) {
        final bytes = utf8.encode('$line\n');
        _pendingLines.add((
          day: DateTime.utc(now.year, now.month, now.day),
          bytes: bytes,
        ));
        _pendingBytes += bytes.length;
        if (flush || level == 'error' || level == 'fatal') {
          this.flush();
        } else if (_pendingBytes >= min(64 * 1024, maxFileBytes)) {
          _drain(sync: false);
        } else {
          _flushTimer ??= Timer(const Duration(milliseconds: 250), () {
            _drain(sync: false);
          });
        }
      }
    } catch (_) {
      storageError = '部分诊断信息无法记录';
    } finally {
      _writing = false;
    }
  }

  /// Ordinary operation bursts share an append instead of opening/stat-ing a
  /// file for every event. Critical records drain earlier context in order.
  void flush() => _drain(sync: true);

  void _drain({required bool sync}) {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pendingLines.isEmpty) return;
    final lines = _pendingLines.toList();
    _pendingLines.clear();
    _pendingBytes = 0;
    try {
      // Refresh metadata once per batch, including externally removed files.
      final current = _current;
      if (current != null) {
        if (current.existsSync()) {
          _currentBytes = current.lengthSync();
        } else {
          _current = null;
          _currentBytes = 0;
        }
      }
      var index = 0;
      while (index < lines.length) {
        final first = lines[index];
        if (_current == null ||
            _fileDay != first.day ||
            _currentBytes + first.bytes.length > maxFileBytes) {
          _current = File(
            p.join(directory!.path, 'app-$session-${_part++}.jsonl'),
          );
          _fileDay = first.day;
          _currentBytes = 0;
          _current!.createSync();
          _prune();
        }
        final batch = BytesBuilder(copy: false);
        do {
          batch.add(lines[index++].bytes);
        } while (index < lines.length &&
            lines[index].day == first.day &&
            _currentBytes + batch.length + lines[index].bytes.length <=
                maxFileBytes);
        final bytes = batch.takeBytes();
        _current!.writeAsBytesSync(bytes, mode: FileMode.append, flush: sync);
        _currentBytes += bytes.length;
      }
      storageError = null;
    } catch (_) {
      storageError = '日志写入失败，可能存储空间不足；最近记录暂存在内存中';
    }
  }

  List<File> _files() {
    final root = directory;
    if (root == null || !root.existsSync()) return [];
    return root
        .listSync(followLinks: false)
        .whereType<File>()
        .where(
          (file) => RegExp(
            r'^app-[0-9]+-[a-f0-9]+-[0-9]+\.jsonl$',
          ).hasMatch(p.basename(file.path)),
        )
        .toList()
      ..sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
  }

  void _prune() {
    final all = _files();
    for (final file in all.toList()) {
      final expired = clock().difference(file.lastModifiedSync()) > retention;
      // Files created within one filesystem timestamp tick may sort together.
      // Never prune the new active file just because its mtime ties an old one.
      if (file.path == _current?.path && !expired) continue;
      if (expired || all.length > maxFiles) {
        if (file.path == _current?.path) {
          _current = null;
          _currentBytes = 0;
        }
        file.deleteSync();
        all.remove(file);
      }
    }
  }

  Map<String, String> exportFiles() {
    flush();
    final result = <String, String>{};
    try {
      _prune();
      for (final file in _files().reversed.take(maxFiles).toList().reversed) {
        try {
          final handle = file.openSync();
          List<int> bytes;
          try {
            bytes = handle.readSync(maxFileBytes);
          } finally {
            handle.closeSync();
          }
          final lines = utf8.decode(bytes, allowMalformed: true).split('\n');
          result[p.basename(file.path)] = lines
              .where((line) => line.isNotEmpty)
              .map<String?>((line) {
                try {
                  final data = jsonDecode(line);
                  if (data is! Map) return null;
                  final time = DateTime.tryParse('${data['time']}');
                  if (time != null && clock().difference(time) > retention) {
                    return null;
                  }
                  return LogRedactor.json(data);
                } catch (_) {
                  return jsonEncode({
                    'event': 'log.partial',
                    'message': '上次写入中断，已跳过不完整记录',
                  });
                }
              })
              .whereType<String>()
              .join('\n');
        } catch (_) {
          storageError = '部分历史日志无法读取，已保留可读取内容';
        }
      }
    } catch (_) {
      storageError = '部分历史日志无法读取，已保留可读取内容';
    }
    if (result.isEmpty || storageError != null || directory == null) {
      result['recent-memory.jsonl'] = _memory
          .where((line) {
            final data = jsonDecode(line) as Map;
            final time = DateTime.tryParse('${data['time']}');
            return time == null || clock().difference(time) <= retention;
          })
          .join('\n');
    }
    return result;
  }

  List<LogEntry> entries({bool errorsOnly = false}) {
    final result = <LogEntry>[];
    for (final content in exportFiles().values) {
      for (final line in const LineSplitter().convert(content)) {
        try {
          final data = jsonDecode(line) as Map<String, dynamic>;
          if (!errorsOnly ||
              {'warning', 'error', 'fatal'}.contains(data['level'])) {
            result.add(LogEntry(data));
          }
        } catch (_) {
          /* A truncated last line after a hard crash is expected. */
        }
      }
    }
    result.sort((a, b) => b.time.compareTo(a.time));
    return result.take(100).toList();
  }

  int get sizeBytes {
    flush();
    try {
      if (directory == null) {
        return _memory.fold(
          0,
          (total, line) => total + utf8.encode(line).length,
        );
      }
      return _files().fold(0, (total, file) => total + file.lengthSync());
    } catch (_) {
      return _memory.fold(0, (total, line) => total + utf8.encode(line).length);
    }
  }

  void lifecycle(String state) {
    if (!_enabled || _closed) return;
    try {
      if (directory != null) {
        File(p.join(directory!.path, 'session.json')).writeAsStringSync(
          jsonEncode({
            'session': session,
            'state': state,
            'time': clock().toUtc().toIso8601String(),
          }),
          flush: true,
        );
      }
    } catch (_) {
      /* Session markers are advisory, never proof of a crash. */
    }
    record('lifecycle.$state', flush: true);
  }

  void setEnabled(bool enabled) {
    if (_closed) return;
    flush();
    if (directory != null) {
      directory!.createSync(recursive: true);
      final flag = File(p.join(directory!.path, 'disabled'));
      if (enabled) {
        if (flag.existsSync()) flag.deleteSync();
      } else {
        flag.writeAsStringSync('disabled', flush: true);
      }
    }
    _enabled = enabled;
    if (enabled) {
      lifecycle('recording_enabled');
    } else {
      _removeMarker();
    }
    notifyListeners();
  }

  void clear() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingLines.clear();
    _pendingBytes = 0;
    for (final file in _files()) {
      file.deleteSync();
    }
    _memory.clear();
    _recent.clear();
    _current = null;
    _currentBytes = 0;
    _fileDay = null;
    _suppressed = 0;
    previousSessionInterrupted = false;
    storageError = null;
    notifyListeners();
  }

  void _removeMarker() {
    try {
      if (directory != null) {
        final marker = File(p.join(directory!.path, 'session.json'));
        if (marker.existsSync()) marker.deleteSync();
      }
    } catch (_) {
      /* No shutdown error should be caused by diagnostics. */
    }
  }

  void close() {
    if (_closed) return;
    record('session.close', flush: true);
    _removeMarker();
    _closed = true;
    if (identical(active, this)) active = null;
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
