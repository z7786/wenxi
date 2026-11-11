import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../diagnostics/app_log.dart';

/// Low frequency numeric samples. Collection never delays playback or disposal.
class PlaybackDiagnostics {
  PlaybackDiagnostics({Future<Object?> Function()? readMemory})
    : _readMemory =
          readMemory ??
          (Platform.isAndroid
              ? () => _channel.invokeMethod<Object?>('diagnosticMemory')
              : null);

  static const interval = Duration(seconds: 30);
  static const slowInterval = Duration(minutes: 2);
  static const _channel = MethodChannel('com.asterlink.app/native');
  static const _memoryKeys = {
    'pid',
    'sampleElapsedMs',
    'sampleCostMs',
    'pssKb',
    'rssKb',
    'privateDirtyKb',
    'nativeHeapAllocatedBytes',
    'javaHeapUsedBytes',
    'javaHeapPrivateKb',
    'nativeHeapPrivateKb',
    'graphicsPrivateKb',
    'stackPrivateKb',
    'swapKb',
    'threadCount',
  };
  final Future<Object?> Function()? _readMemory;
  bool get supported => _readMemory != null;
  int _generation = 0;
  bool _closed = false, _sampling = false;
  Duration? _lastSample;
  Duration _sampleInterval = interval;
  Map<String, num>? _baseline;
  Map<String, Object?> _context = const {};
  Map<String, Object?> get context => _context;

  void begin(Map<String, Object?> context) {
    if (_closed) return;
    _generation++;
    _lastSample = null;
    _baseline = null;
    _context = Map.of(context);
  }

  Future<void> sample(
    Duration elapsed,
    Map<String, Object?> Function() fields,
  ) async {
    final log = DiagnosticLog.active;
    if (_closed ||
        _sampling ||
        _readMemory == null ||
        log?.enabled != true ||
        (_lastSample != null && elapsed - _lastSample! < _sampleInterval)) {
      return;
    }
    _lastSample = elapsed;
    _sampling = true;
    final generation = _generation;
    final context = _context;
    try {
      final snapshot = fields();
      final memory = await _memory();
      if (_closed || generation != _generation || log?.enabled != true) return;
      if (memory.isEmpty) return;
      if ((memory['sampleCostMs'] ?? 0) >= 100) _sampleInterval = slowInterval;
      final first = _baseline == null;
      _baseline ??= memory;
      log!.record(
        'player.memory_sample',
        fields: {
          ...context,
          ...snapshot,
          'memorySampleIntervalMs': _sampleInterval.inMilliseconds,
          'memoryPhase': first ? 'baseline' : 'playing',
          'memory': memory,
          'memoryDelta': {
            for (final key in ['rssKb', 'pssKb', 'nativeHeapAllocatedBytes'])
              if (memory[key] != null && _baseline![key] != null)
                key: memory[key]! - _baseline![key]!,
          },
        },
      );
    } on TimeoutException {
      _sampleInterval = slowInterval;
    } catch (_) {
      // Missing bridges, revoked access or slow counters do not affect playback.
    } finally {
      _sampling = false;
    }
  }

  void stop() {
    _closed = true;
    _generation++;
  }

  Future<void> afterClose(
    Map<String, Object?> fields, {
    String phase = 'stopped',
  }) async {
    final log = DiagnosticLog.active;
    if (_readMemory == null || log?.enabled != true) return;
    try {
      final memory = await _memory();
      if (memory.isEmpty || log?.enabled != true) return;
      log!.record(
        'player.memory_after_close',
        fields: {
          ..._context,
          ...fields,
          'memoryPhase': phase,
          'memory': memory,
        },
      );
    } catch (_) {
      // Decoder teardown must complete even if diagnostics are unavailable.
    }
  }

  Future<Map<String, num>> _memory() async {
    final raw = await _readMemory!().timeout(const Duration(seconds: 2));
    return {
      if (raw is Map)
        for (final key in _memoryKeys)
          if (raw[key] is num && (raw[key] as num).isFinite)
            key: raw[key] as num,
    };
  }
}
