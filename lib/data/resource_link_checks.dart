import 'dart:async';
import 'dart:collection';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/resource_search.dart';

enum ResourceLinkState {
  pending,
  checking,
  valid,
  invalid,
  locked,
  unknown,
  unsupported,
}

class ResourceLinkHealth {
  const ResourceLinkHealth(this.state, {this.message = '', this.checkedAt});
  final ResourceLinkState state;
  final String message;
  final DateTime? checkedAt;
  bool get settled =>
      state != ResourceLinkState.pending && state != ResourceLinkState.checking;
  int get sortRank => switch (state) {
    ResourceLinkState.valid => 0,
    ResourceLinkState.invalid => 2,
    _ => 1,
  };
  String get label => switch (state) {
    ResourceLinkState.pending => '待检测',
    ResourceLinkState.checking => '检测中',
    ResourceLinkState.valid => '链接有效',
    ResourceLinkState.invalid => '链接失效',
    ResourceLinkState.locked => '提取码待确认',
    ResourceLinkState.unknown => '暂无法确认',
    ResourceLinkState.unsupported => '暂不支持检测',
  };

  factory ResourceLinkHealth.checked(
    ResourceLinkState state,
    DateTime checkedAt,
  ) => ResourceLinkHealth(
    state,
    checkedAt: checkedAt,
    message: switch (state) {
      ResourceLinkState.valid => '本机网络检测到分享可访问，打开时以网盘实际状态为准。',
      ResourceLinkState.invalid => '网盘明确返回分享失效、被取消或内容为空，可以重新检测。',
      ResourceLinkState.locked => '提取码缺失或未通过验证，可以打开分享后确认提取码。',
      ResourceLinkState.unsupported => '该类型暂未内置检测规则，可继续尝试打开。',
      _ => '当前网络、验证码或网盘访问限制使状态无法确认，可继续尝试打开。',
    },
  );
}

String resourceLinkKey(ResourceSearchHit hit) =>
    '${hit.identity}\u0000${hit.password}';
bool canCheckResourceLink(ResourceSearchHit hit) =>
    hit.link?.kind == LinkKind.cloudShare;
String _provider(ResourceSearchHit hit) =>
    hit.platform?.key ?? Uri.parse(hit.url).host;

abstract class ResourceLinkCheckApi {
  Future<ResourceLinkHealth> check(
    ResourceSearchHit hit,
    CancelToken cancellation,
  );
  void dispose() {}
}

class ResourceLinkCheckLimited implements Exception {}

/// Checks returned search links before publication. Completed states are pinned
/// for the batch so cache expiry cannot restart earlier checks in a long search.
class ResourceLinkCheckBatch {
  ResourceLinkCheckBatch._(this._owner);
  final ResourceLinkChecks _owner;
  final _hits = <String, ResourceSearchHit>{};
  final _results = <String, ResourceLinkHealth>{};
  final _completion = Completer<void>();
  bool _sealed = false, _closed = false, _paused = false;

  int get totalCount => _hits.length;
  int get checkedCount => _results.length;
  bool get paused => _paused;
  Map<String, ResourceLinkHealth> get results => UnmodifiableMapView(_results);

  void update(Iterable<ResourceSearchHit> hits) =>
      _owner._updateBatch(this, hits);

  Future<void> finish() {
    if (!_closed) {
      _sealed = true;
      _owner._pump();
    }
    return _completion.future;
  }

  void pause() => _owner._setBatchPaused(this, true);

  void resume() => _owner._setBatchPaused(this, false);

  void cancel() => _owner._closeBatch(this, cancel: true);
}

/// A bounded queue shared by pre-publication search batches and visible
/// recommendations. Probes never transfer shares; cache keys include passwords.
class ResourceLinkChecks extends ChangeNotifier {
  ResourceLinkChecks(
    this.api, {
    this.clock = DateTime.now,
    this.debounce = const Duration(milliseconds: 180),
    this.concurrency = 3,
    this.timeout = const Duration(seconds: 16),
  }) : assert(concurrency > 0),
       assert(timeout > Duration.zero);
  final ResourceLinkCheckApi api;
  final DateTime Function() clock;
  final Duration debounce, timeout;
  final int concurrency;
  final _cache = <String, (DateTime, ResourceLinkHealth)>{};
  final _active = <String, CancelToken>{};
  final _deadlines = <CancelToken, Timer>{};
  final _limitedUntil = <String, DateTime>{};
  Map<String, ResourceSearchHit> _visible = {};
  ResourceLinkCheckBatch? _batch;
  Timer? _debounce, _cooldown;
  bool _closed = false;

  ResourceLinkHealth health(ResourceSearchHit hit) {
    if (!canCheckResourceLink(hit)) {
      return const ResourceLinkHealth(
        ResourceLinkState.unsupported,
        message: '该类型暂未内置检测规则，可继续尝试打开。',
      );
    }
    final key = resourceLinkKey(hit);
    if (_active.containsKey(key)) {
      return const ResourceLinkHealth(ResourceLinkState.checking);
    }
    final pinned = _batch?._results[key];
    if (pinned != null) return pinned;
    final cached = _cache[key];
    if (cached != null && clock().isBefore(cached.$1)) return cached.$2;
    final until = _limitedUntil[_provider(hit)];
    if (until != null && clock().isBefore(until)) {
      return const ResourceLinkHealth(
        ResourceLinkState.unknown,
        message: '该网盘检测较频繁，请稍后再试。',
      );
    }
    return const ResourceLinkHealth(ResourceLinkState.pending);
  }

  /// Valid, unconfirmed, then explicitly invalid, preserving order within each
  /// group. Call before publication, rather than during scrolling.
  List<ResourceSearchHit> orderHits(Iterable<ResourceSearchHit> hits) {
    final values = hits.toList();
    final original = {
      for (final (index, hit) in values.indexed) resourceLinkKey(hit): index,
    };
    values.sort((a, b) {
      final result = health(a).sortRank.compareTo(health(b).sortRank);
      return result == 0
          ? original[resourceLinkKey(a)]!.compareTo(
              original[resourceLinkKey(b)]!,
            )
          : result;
    });
    return values;
  }

  void setVisible(Iterable<ResourceSearchHit> hits) {
    if (_closed || _batch != null) return;
    final next = {
      for (final hit in hits.where(canCheckResourceLink).take(50))
        resourceLinkKey(hit): hit,
    };
    if (mapEquals(
      next.map((k, v) => MapEntry(k, v.identity)),
      _visible.map((k, v) => MapEntry(k, v.identity)),
    )) {
      if (_debounce == null &&
          next.values.any(
            (hit) => health(hit).state == ResourceLinkState.pending,
          )) {
        _schedule();
      }
      return;
    }
    _visible = next;
    for (final key in _active.keys.toList()) {
      if (!next.containsKey(key)) _cancelProbe(key);
    }
    _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      _debounce = null;
      _pump();
    });
  }

  void clearVisible() {
    _debounce?.cancel();
    _debounce = null;
    _cooldown?.cancel();
    _cooldown = null;
    _visible = {};
    if (_batch == null) _cancelActive();
  }

  void _cancelActive() {
    for (final key in _active.keys.toList()) {
      _cancelProbe(key);
    }
  }

  void _cancelProbe(String key) {
    final token = _active.remove(key);
    if (token == null) return;
    _deadlines.remove(token)?.cancel();
    token.cancel();
  }

  ResourceLinkCheckBatch beginBatch() {
    assert(!_closed);
    _batch?.cancel();
    clearVisible();
    return _batch = ResourceLinkCheckBatch._(this);
  }

  void _updateBatch(
    ResourceLinkCheckBatch batch,
    Iterable<ResourceSearchHit> hits,
  ) {
    if (_closed || batch._closed || batch._sealed || _batch != batch) return;
    final next = {for (final hit in hits) resourceLinkKey(hit): hit};
    batch._hits
      ..clear()
      ..addAll(next);
    batch._results.removeWhere((key, _) => !next.containsKey(key));
    for (final key in _active.keys.toList()) {
      if (!next.containsKey(key)) _cancelProbe(key);
    }
    _pump();
  }

  void _closeBatch(ResourceLinkCheckBatch batch, {bool cancel = false}) {
    if (batch._closed) return;
    batch._closed = true;
    if (_batch == batch) {
      if (cancel) _cancelActive();
      _batch = null;
    }
    batch._completion.complete();
  }

  void _setBatchPaused(ResourceLinkCheckBatch batch, bool paused) {
    if (_closed ||
        batch._closed ||
        batch._paused == paused ||
        _batch != batch) {
      return;
    }
    batch._paused = paused;
    if (paused) {
      _cancelActive();
    } else {
      _pump();
    }
    notifyListeners();
  }

  void retry(ResourceSearchHit hit) {
    if (_closed || !canCheckResourceLink(hit)) return;
    final key = resourceLinkKey(hit);
    if (_active.containsKey(key)) return;
    _cache.remove(key);
    if (_batch case final batch?) {
      if (!batch._hits.containsKey(key)) return;
      batch._results.remove(key);
      final remaining = Map<String, ResourceSearchHit>.of(batch._hits);
      batch._hits
        ..clear()
        ..addAll({key: hit, ...remaining});
    } else {
      _visible = {key: hit, ..._visible};
    }
    _pump();
    notifyListeners();
  }

  void _pump() {
    if (_closed) return;
    _cooldown?.cancel();
    _cooldown = null;
    _limitedUntil.removeWhere((_, until) => !clock().isBefore(until));
    if (_batch case final batch?) {
      var changed = false;
      for (final entry in batch._hits.entries) {
        if (batch._results.containsKey(entry.key)) continue;
        final current = health(entry.value);
        if (current.settled) {
          batch._results[entry.key] = current;
          changed = true;
        }
      }
      if (batch._sealed && batch.checkedCount == batch.totalCount) {
        _closeBatch(batch);
        notifyListeners();
        return;
      }
      if (!batch._paused) {
        for (final entry in batch._hits.entries) {
          if (_active.length >= concurrency) break;
          if (batch._results.containsKey(entry.key) ||
              _active.containsKey(entry.key)) {
            continue;
          }
          final token = CancelToken();
          _active[entry.key] = token;
          unawaited(_run(entry.key, entry.value, token));
          changed = true;
        }
      }
      if (changed) notifyListeners();
      return;
    }
    DateTime? wakeAt;
    for (final hit in _visible.values) {
      final until = _limitedUntil[_provider(hit)];
      if (until != null && (wakeAt == null || until.isBefore(wakeAt))) {
        wakeAt = until;
      }
    }
    if (wakeAt != null) _cooldown = Timer(wakeAt.difference(clock()), _pump);
    var started = false;
    for (final entry in _visible.entries) {
      if (_active.length >= concurrency) break;
      if (health(entry.value).state != ResourceLinkState.pending) continue;
      final token = CancelToken();
      _active[entry.key] = token;
      unawaited(_run(entry.key, entry.value, token));
      started = true;
    }
    if (started) notifyListeners();
  }

  Future<void> _run(
    String key,
    ResourceSearchHit hit,
    CancelToken token,
  ) async {
    ResourceLinkHealth result;
    var timedOut = false;
    final expired = Completer<ResourceLinkHealth>();
    final deadline = Timer(timeout, () {
      timedOut = true;
      expired.completeError(TimeoutException('Link check timed out'));
    });
    _deadlines[token] = deadline;
    try {
      result = await Future.any([
        Future.sync(() => api.check(hit, token)),
        expired.future,
        token.whenCancel.then<ResourceLinkHealth>(
          (_) => throw StateError('cancelled'),
        ),
      ]);
      if (!result.settled) {
        result = ResourceLinkHealth.checked(ResourceLinkState.unknown, clock());
      } else if (result.checkedAt == null) {
        result = ResourceLinkHealth(
          result.state,
          message: result.message,
          checkedAt: clock(),
        );
      }
    } catch (e) {
      result = ResourceLinkHealth(
        ResourceLinkState.unknown,
        checkedAt: clock(),
        message: e is ResourceLinkCheckLimited
            ? '该网盘检测较频繁，请稍后再试。'
            : '本机检测超时或网络异常，可以稍后重新检测。',
      );
      if (!token.isCancelled && e is ResourceLinkCheckLimited) {
        _limitedUntil[_provider(hit)] = clock().add(const Duration(minutes: 1));
      }
    } finally {
      deadline.cancel();
      _deadlines.remove(token);
    }
    if (_closed || token.isCancelled || !identical(_active[key], token)) return;
    _active.remove(key);
    if (timedOut) token.cancel('deadline');
    final batch = _batch;
    if (batch != null && batch._hits.containsKey(key)) {
      batch._results[key] = result;
    }
    final ttl = switch (result.state) {
      ResourceLinkState.valid => const Duration(minutes: 10),
      ResourceLinkState.invalid => const Duration(minutes: 3),
      ResourceLinkState.unsupported => const Duration(minutes: 30),
      _ => const Duration(minutes: 1),
    };
    _cache[key] = (clock().add(ttl), result);
    while (_cache.length > 1200) {
      _cache.remove(_cache.keys.first);
    }
    notifyListeners();
    _pump();
  }

  @override
  void dispose() {
    _closed = true;
    _batch?.cancel();
    clearVisible();
    api.dispose();
    super.dispose();
  }
}
