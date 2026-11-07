import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../diagnostics/app_log.dart';
import '../domain/github_update.dart';
import '../domain/models.dart';
import '../domain/remote_control.dart';
import 'github_update_service.dart';
import 'remote_control_http.dart';
import 'state_store.dart';

enum ControlRefreshResult {
  success,
  partial,
  fallback,
  failed,
  unconfigured,
  skipped,
  closed,
}

class RemoteControlService extends ChangeNotifier {
  RemoteControlService(
    this.store, {
    required this.platform,
    required this.currentBuild,
    this.currentVersion = applicationVersion,
    String configUrl = buildUrl,
    this.enabled = buildEnabled,
    RemoteControlFetcher? fetcher,
    this.githubUpdates,
    this.clock = DateTime.now,
  }) : _fetcher = fetcher ?? DioRemoteControlFetcher() {
    if (enabled) {
      try {
        final value = httpsUri(
          configUrl.trim().isEmpty ? defaultUrl : configUrl.trim(),
        );
        if (value.hasFragment) throw const FormatException('配置地址不能含片段');
        _endpoint = value;
      } on FormatException {
        _lastFailure = 'invalid_endpoint';
        _lastError = '在线配置地址无效，请检查构建设置';
        DiagnosticLog.event('control.invalid_endpoint');
      }
    }
    _readCache();
  }

  static const defaultUrl = '';
  static const buildUrl = String.fromEnvironment(
    'ASTERLINK_CONTROL_URL',
    defaultValue: defaultUrl,
  );
  static const buildEnabled = bool.fromEnvironment(
    'ASTERLINK_CONTROL_ENABLED',
    defaultValue: false,
  );
  static const refreshInterval = Duration(minutes: 15);
  static const announcementMuteDuration = Duration(days: 7);
  static const legacyRestrictionLifetime = Duration(days: 7);
  static const retryDelays = [
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  static const cacheKey = 'remoteControlCache';
  static const seenKey = 'remoteControlSeen';
  final StateStore store;
  final String platform;
  final int currentBuild;
  final String currentVersion;
  final GitHubUpdateService? githubUpdates;
  final bool enabled;
  final DateTime Function() clock;
  final RemoteControlFetcher _fetcher;
  Uri? _endpoint;
  RemoteControlConfig? _cached;
  String? _fingerprint;
  DateTime? _fetchedAt, _lastAttempt, _nextAttempt, _nextSave;
  final _sectionVerifiedAt = <String, DateTime>{};
  final _sectionRevisions = <String, int>{};
  List<ControlConfigIssue> _issues = const [];
  Future<ControlRefreshResult>? _pending;
  Future<void>? _cacheWriting;
  Json? _cacheToSave;
  Timer? _pollTimer, _expiryTimer, _announcementTimer, _cacheRetryTimer;
  int _failures = 0, _saveFailures = 0;
  bool _closed = false, _foreground = false, _loadedFromCache = false;
  String? _lastError, _lastFailure, _errorPath, _saveError;
  final _dismissedAnnouncements = <String, String>{};
  String? _announcementMutedContentKey;
  DateTime? _announcementMutedUntil;
  final _dismissedUpdates = <int>{};
  final _ignoredUpdates = <String, int>{};
  final _dismissedGithubUpdates = <String>{};
  final _ignoredGithubUpdates = <String>{};
  bool _githubActive = false, _githubChecked = false;
  RemoteUpdate? _githubLatest;

  bool get configured => _endpoint != null;
  bool get inForeground => !_closed && _foreground;
  bool get checking => _pending != null;
  String? get lastError => _lastError ?? _saveError;
  DateTime? get lastSuccess => _fetchedAt;
  List<ControlConfigIssue> get issues => _issues;
  bool get cachePersisted => _cached != null && _cacheToSave == null;
  bool get hasFreshConfig {
    final fetched = _fetchedAt;
    if (_cached == null || fetched == null) return false;
    final age = clock().difference(fetched);
    return age >= Duration.zero && age < refreshInterval;
  }

  bool get usingCache =>
      _cached != null &&
      (_loadedFromCache ||
          !hasFreshConfig ||
          _lastFailure != null ||
          _issues.isNotEmpty);
  String get statusText => !enabled
      ? '离线模式'
      : !configured
      ? '配置地址无效'
      : _cached == null
      ? (checking ? '正在获取' : '尚未获取有效配置')
      : _issues.isNotEmpty
      ? '部分生效'
      : usingCache
      ? '使用缓存'
      : '正常';

  DateTime? _deadline(String section, DateTime? explicit) =>
      explicit ?? _sectionVerifiedAt[section]?.add(legacyRestrictionLifetime);
  bool _expired(String section, DateTime? explicit, DateTime now) {
    final end = _deadline(section, explicit);
    return end == null || !now.isBefore(end);
  }

  RemoteControlConfig get config {
    final cached = _cached;
    if (cached == null) return RemoteControlConfig.defaults;
    final now = clock();
    return RemoteControlConfig(
      revision: cached.revision,
      announcement: cached.announcement,
      aboutDescription: cached.aboutDescription,
      helpUrl: cached.helpUrl,
      parserHubUrl: cached.parserHubUrl,
      clouds: {
        for (final entry in cached.clouds.entries)
          entry.key:
              !entry.value.enabled &&
                  _expired(
                    'clouds.${entry.key.name}',
                    entry.value.expiresAt,
                    now,
                  )
              ? const CloudControl()
              : entry.value,
      },
      updates: {
        for (final entry in cached.updates.entries)
          entry.key:
              entry.value.force &&
                  _expired('updates.${entry.key}', entry.value.expiresAt, now)
              ? RemoteUpdate(
                  entry.value.version,
                  entry.value.build,
                  entry.value.downloadUrl,
                  entry.value.notes,
                  inAppDownloadUrl: entry.value.inAppDownloadUrl,
                  inAppPasscode: entry.value.inAppPasscode,
                )
              : entry.value,
      },
    );
  }

  String? errorForSection(String section) {
    if (section == 'updates.$platform' && usingGithubUpdates) return null;
    if (_lastFailure != null && _lastFailure != 'partial_config') {
      return _lastError;
    }
    return _issues.any((issue) => issue.section == section)
        ? '这项在线信息格式有误，已保留上次有效内容'
        : null;
  }

  String get _localAnnouncementDate {
    final today = clock().toLocal();
    return '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
  }

  bool isAnnouncementMuted(RemoteAnnouncement notice) =>
      _announcementMutedContentKey == notice.contentKey &&
      _announcementMutedUntil != null &&
      clock().isBefore(_announcementMutedUntil!);

  bool get announcementMuted {
    final notice = config.announcement;
    return notice != null && isAnnouncementMuted(notice);
  }

  RemoteAnnouncement? get unreadAnnouncement {
    final notice = config.announcement;
    return notice == null ||
            isAnnouncementMuted(notice) ||
            _dismissedAnnouncements[notice.contentKey] == _localAnnouncementDate
        ? null
        : notice;
  }

  RemoteUpdate? get availableUpdate {
    final update = config.updates[platform];
    final primary = update != null && update.build > currentBuild
        ? update
        : null;
    // A fallback release cannot withdraw an existing required-update policy.
    if (primary?.force == true) return primary;
    final github = _githubLatest;
    if (usingGithubUpdates &&
        github != null &&
        GitHubReleaseParser.newerThan(github, currentVersion, currentBuild)) {
      return github;
    }
    return primary;
  }

  bool get usingGithubUpdates => _githubActive && _githubChecked;

  bool get hasUpdateInformation => usingGithubUpdates
      ? _githubLatest != null
      : config.updates[platform] != null;

  RemoteUpdate? get unreadUpdate {
    final update = availableUpdate;
    if (update == null || update.force) return update;
    if (update.releaseKey != null) {
      return _dismissedGithubUpdates.contains(update.key) ||
              _ignoredGithubUpdates.contains(update.key)
          ? null
          : update;
    }
    return _dismissedUpdates.contains(update.build) ||
            update.build <= (_ignoredUpdates[platform] ?? 0)
        ? null
        : update;
  }

  RemoteUpdate? get requiredUpdate {
    final update = availableUpdate;
    return update?.force == true ? update : null;
  }

  bool cloudEnabled(CloudPlatform p) => config.cloud(p).enabled;
  void checkCloud(CloudPlatform p) {
    final control = config.cloud(p);
    if (!control.enabled) throw AppException(control.reason(p));
  }

  void _readCache() {
    if (!configured) return;
    try {
      final cache = store.data.obj(cacheKey);
      if (cache['endpoint'] == _endpoint.toString()) {
        final stamp = cache['fetchedAt'];
        if (stamp is int && stamp > 0) {
          final fetched = DateTime.fromMillisecondsSinceEpoch(stamp);
          if (!fetched.isAfter(clock())) {
            final document = RemoteControlDocument.decode(
              jsonEncode(cache['control']),
            );
            final restored = document.validated;
            final fingerprint = cache['fingerprint'];
            _cached = restored;
            _fingerprint = fingerprint is String
                ? fingerprint
                : document.fingerprint;
            _fetchedAt = fetched;
            _loadedFromCache = true;
            final sections = cache.obj('sections');
            for (final section in RemoteControlDocument.sectionNames) {
              final meta = sections.obj(section), time = meta['verifiedAt'];
              if (cache['version'] == 2 &&
                  (time is! int || time <= 0 || time > stamp)) {
                continue;
              }
              final verified = time is int && time > 0 && time <= stamp
                  ? DateTime.fromMillisecondsSinceEpoch(time)
                  : fetched;
              _sectionVerifiedAt[section] = verified;
              final revision = meta['revision'];
              _sectionRevisions[section] = revision is int
                  ? revision
                  : restored.revision;
            }
            _issues = List.unmodifiable([
              for (final row in cache.list('issues'))
                if (row['section'] is String &&
                    row['path'] is String &&
                    (RemoteControlDocument.sectionNames.contains(
                          row['section'],
                        ) ||
                        row['section'] == 'clouds') &&
                    ControlConfigIssue.isKnownPath(row['path']))
                  ControlConfigIssue(
                    row['section'],
                    row['path'],
                    '请检查该字段的已发布内容',
                  ),
            ]);
          }
        }
      }
    } catch (_) {
      _cached = null;
      _fingerprint = null;
      _fetchedAt = null;
      _loadedFromCache = false;
      _issues = const [];
      _sectionVerifiedAt.clear();
      _sectionRevisions.clear();
      DiagnosticLog.event('control.invalid_cache');
    }
    final seen = store.data.obj(seenKey);
    if (seen['endpoint'] != _endpoint.toString()) return;
    // Legacy day-wide mutes have no content identity and must not hide updates.
    final mute = seen.obj('announcementMute');
    final contentKey = mute['contentKey'], until = mute['until'];
    final now = clock().millisecondsSinceEpoch;
    if (contentKey is String &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(contentKey) &&
        until is int &&
        until > now &&
        until <= now + announcementMuteDuration.inMilliseconds) {
      _announcementMutedContentKey = contentKey;
      _announcementMutedUntil = DateTime.fromMillisecondsSinceEpoch(until);
    }
    final ignored = seen['ignoredUpdates'];
    if (ignored is Map) {
      for (final platform in remoteUpdatePlatforms) {
        final build = ignored[platform];
        if (build is int && build > 0 && build <= 2147483647) {
          _ignoredUpdates[platform] = build;
        }
      }
    }
    final githubIgnored = seen['ignoredGithubUpdates'];
    if (githubIgnored is List) {
      _ignoredGithubUpdates.addAll(
        githubIgnored
            .whereType<String>()
            .where((key) => key.startsWith('github:') && key.length <= 256)
            .take(64),
      );
    }
  }

  void setForeground(bool value) {
    if (_closed) return;
    final entering = value && !_foreground;
    _foreground = value;
    _cancelTimers();
    if (!value || !configured) return;
    notifyListeners();
    final since = _lastAttempt == null
        ? null
        : clock().difference(_lastAttempt!);
    final retryNow =
        entering &&
        _failures > 0 &&
        (since == null || since >= retryDelays.first);
    unawaited(refresh(force: retryNow));
    _schedule();
  }

  void _cancelTimers() {
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    _announcementTimer?.cancel();
    _cacheRetryTimer?.cancel();
  }

  void _schedule() {
    _cancelTimers();
    if (_closed || !_foreground || !configured) return;
    final now = clock();
    Duration until(DateTime? time) {
      final remaining = (time ?? now.add(refreshInterval)).difference(now);
      return remaining > Duration.zero ? remaining : Duration.zero;
    }

    if (!checking) {
      _pollTimer = Timer(until(_nextAttempt), () => unawaited(refresh()));
    }
    final deadlines = <DateTime>[
      for (final p in CloudPlatform.values)
        if (_cached?.cloud(p).enabled == false)
          ?_deadline('clouds.${p.name}', _cached!.cloud(p).expiresAt),
      for (final entry
          in _cached?.updates.entries ?? <MapEntry<String, RemoteUpdate>>[])
        if (entry.value.force)
          ?_deadline('updates.${entry.key}', entry.value.expiresAt),
    ].where((time) => time.isAfter(now)).toList()..sort();
    if (deadlines.isNotEmpty) {
      _expiryTimer = Timer(until(deadlines.first), () {
        if (_closed || !_foreground) return;
        notifyListeners();
        _schedule();
      });
    }
    if (_cached?.announcement != null) {
      final local = now.toLocal();
      var next = DateTime(local.year, local.month, local.day + 1);
      final mutedUntil = _announcementMutedUntil;
      if (isAnnouncementMuted(_cached!.announcement!) &&
          mutedUntil != null &&
          mutedUntil.isBefore(next)) {
        next = mutedUntil;
      }
      _announcementTimer = Timer(until(next), () {
        if (_closed || !_foreground) return;
        notifyListeners();
        _schedule();
      });
    }
    if (_cacheToSave != null && _cacheWriting == null && _nextSave != null) {
      _cacheRetryTimer = Timer(until(_nextSave), _startCacheSave);
    }
  }

  Future<ControlRefreshResult> refresh({bool force = false}) {
    if (_closed) return Future.value(ControlRefreshResult.closed);
    if (!configured) return Future.value(ControlRefreshResult.unconfigured);
    if (_pending case final pending?) return pending;
    final now = clock();
    final clockMovedBack = _lastAttempt != null && now.isBefore(_lastAttempt!);
    if (!force &&
        !clockMovedBack &&
        _nextAttempt != null &&
        now.isBefore(_nextAttempt!)) {
      _schedule();
      return Future.value(ControlRefreshResult.skipped);
    }
    final completer = Completer<ControlRefreshResult>();
    _pending = completer.future;
    _lastAttempt = now;
    notifyListeners();
    unawaited(
      _fetch(force: force).then((result) {
        _pending = null;
        if (result == ControlRefreshResult.success) {
          _failures = 0;
          _nextAttempt = clock().add(refreshInterval);
        } else if (result == ControlRefreshResult.failed ||
            result == ControlRefreshResult.partial ||
            result == ControlRefreshResult.fallback) {
          _nextAttempt = clock().add(
            retryDelays[_failures.clamp(0, retryDelays.length - 1)],
          );
          _failures++;
        }
        if (!_closed) {
          _schedule();
          notifyListeners();
        }
        completer.complete(result);
      }),
    );
    return completer.future;
  }

  Future<ControlRefreshResult> _fetch({required bool force}) async {
    var failure = 'fetch_failed';
    try {
      final text = await _fetcher.fetch(_endpoint!);
      if (_closed) return ControlRefreshResult.closed;
      _githubActive = false;
      _githubChecked = false;
      _githubLatest = null;
      failure = 'invalid_config';
      final document = RemoteControlDocument.decode(
        text,
        previous: _cached ?? RemoteControlConfig.defaults,
      );
      final next = document.config;
      final fetched = clock();
      _cached = next;
      _fingerprint = document.fingerprint;
      _fetchedAt = fetched;
      _loadedFromCache = false;
      _issues = document.issues;
      for (final section in document.validSections) {
        _sectionVerifiedAt[section] = fetched;
        _sectionRevisions[section] = next.revision;
      }
      _errorPath = null;
      _lastFailure = _issues.isEmpty ? null : 'partial_config';
      _lastError = _issues.isEmpty ? null : '部分在线信息有误，已保留对应的上次有效内容';
      // Apply before disk I/O. Persistence failure never undoes verified values.
      _cacheToSave = {
        'version': 2,
        'endpoint': _endpoint.toString(),
        'fetchedAt': fetched.millisecondsSinceEpoch,
        'fingerprint': _fingerprint,
        'control': next.toJson(),
        'sections': {
          for (final section in _sectionVerifiedAt.keys)
            section: {
              'verifiedAt': _sectionVerifiedAt[section]!.millisecondsSinceEpoch,
              'revision': _sectionRevisions[section],
            },
        },
        'issues': _issues.map((issue) => issue.toJson()).toList(),
      };
      _startCacheSave();
      DiagnosticLog.event(
        'control.loaded',
        fields: {
          'revision': next.revision,
          'invalidSections': _issues.map((issue) => issue.path).toList(),
        },
      );
      return _issues.isEmpty
          ? ControlRefreshResult.success
          : ControlRefreshResult.partial;
    } catch (error) {
      if (_closed) return ControlRefreshResult.closed;
      final failed = _failed(failure, error: error);
      final github = githubUpdates;
      // A reachable but malformed document must not trigger another source.
      final inaccessible =
          failure == 'fetch_failed' &&
          (error is ControlAccessException || error is! FormatException);
      _githubActive = inaccessible && github?.configured == true;
      _githubChecked = false;
      _githubLatest = null;
      if (!_githubActive) return failed;
      try {
        final latest = await github!.check(force: force);
        if (_closed) return ControlRefreshResult.closed;
        _githubLatest = latest;
        _githubChecked = true;
        DiagnosticLog.event(
          'control.github_update_checked',
          fields: {
            'platform': platform,
            'hasCompatibleRelease': latest != null,
          },
        );
        return ControlRefreshResult.fallback;
      } catch (error) {
        if (_closed) return ControlRefreshResult.closed;
        DiagnosticLog.event(
          'control.github_update_failed',
          fields: {'type': error.runtimeType.toString()},
        );
        return failed;
      }
    }
  }

  void _startCacheSave({bool allowClosed = false}) {
    if ((_closed && !allowClosed) ||
        _cacheWriting != null ||
        _cacheToSave == null) {
      return;
    }
    _cacheRetryTimer?.cancel();
    _cacheWriting = _saveCache().whenComplete(() {
      _cacheWriting = null;
      if (!_closed) {
        _schedule();
        notifyListeners();
      }
    });
  }

  Future<void> _saveCache() async {
    while (_cacheToSave != null) {
      final snapshot = _cacheToSave!;
      try {
        await store.change((draft) => draft[cacheKey] = snapshot);
        if (identical(_cacheToSave, snapshot)) _cacheToSave = null;
        _saveFailures = 0;
        _nextSave = null;
        _saveError = null;
      } catch (error) {
        _saveError = '在线配置已生效，但暂未保存到本机';
        _nextSave = clock().add(
          retryDelays[_saveFailures.clamp(0, retryDelays.length - 1)],
        );
        _saveFailures++;
        DiagnosticLog.event(
          'control.cache_write_failed',
          fields: {'type': error.runtimeType.toString()},
        );
        return;
      }
    }
  }

  Future<void> flushCache() async {
    // A previously failed write gets one final attempt when the app closes.
    // An active writer already drains newer snapshots before it completes.
    if (_cacheWriting == null && _cacheToSave != null) {
      _startCacheSave(allowClosed: true);
    }
    await _cacheWriting;
  }

  ControlRefreshResult _failed(String reason, {Object? error}) {
    _lastFailure = reason;
    _errorPath = error is ControlFormatException ? error.path : null;
    _lastError = switch (reason) {
      'invalid_config' => '在线配置格式有误，请联系维护者修正',
      _ => '暂时无法获取在线信息，请检查网络后重试',
    };
    DiagnosticLog.event(
      'control.refresh_failed',
      fields: {
        'reason': reason,
        if (error != null) 'type': error.runtimeType.toString(),
        if (_errorPath != null) 'path': _errorPath,
        if (_cached != null) 'cachedRevision': _cached!.revision,
      },
    );
    return ControlRefreshResult.failed;
  }

  Future<void> dismissAnnouncement(
    RemoteAnnouncement notice, {
    bool hideForWeek = false,
  }) async {
    if (_closed || !configured) return;
    final today = _localAnnouncementDate;
    _dismissedAnnouncements[notice.contentKey] = today;
    while (_dismissedAnnouncements.length > 64) {
      _dismissedAnnouncements.remove(_dismissedAnnouncements.keys.first);
    }
    final mutedKey = hideForWeek ? notice.contentKey : null;
    final mutedUntil = hideForWeek
        ? clock().add(announcementMuteDuration)
        : null;
    final changed =
        _announcementMutedContentKey != mutedKey ||
        _announcementMutedUntil != mutedUntil;
    _announcementMutedContentKey = mutedKey;
    _announcementMutedUntil = mutedUntil;
    notifyListeners();
    _schedule();
    // An ordinary close lasts for this run and day only. Only the explicit
    // checkbox is persisted; manually reopening also lets the user clear it.
    if (changed) await _saveSeen();
  }

  // Closing (including opening a download) only suppresses this app session.
  // Window focus and browser round trips do not start a new session.
  Future<void> dismissUpdate(int build, {String? updateKey}) async {
    final update = availableUpdate;
    if (_closed ||
        update == null ||
        update.force ||
        update.build != build ||
        (updateKey != null && updateKey != update.key)) {
      return;
    }
    if (update.releaseKey != null) {
      if (!_dismissedGithubUpdates.add(update.key)) return;
      while (_dismissedGithubUpdates.length > 64) {
        _dismissedGithubUpdates.remove(_dismissedGithubUpdates.first);
      }
      notifyListeners();
      return;
    }
    if (!_dismissedUpdates.add(build)) return;
    while (_dismissedUpdates.length > 64) {
      _dismissedUpdates.remove(_dismissedUpdates.first);
    }
    notifyListeners();
  }

  Future<void> ignoreUpdate(int build, {String? updateKey}) async {
    final update = availableUpdate;
    if (_closed ||
        update == null ||
        update.force ||
        update.build != build ||
        (updateKey != null && updateKey != update.key)) {
      return;
    }
    if (update.releaseKey != null) {
      if (!_ignoredGithubUpdates.add(update.key)) return;
      while (_ignoredGithubUpdates.length > 64) {
        _ignoredGithubUpdates.remove(_ignoredGithubUpdates.first);
      }
      notifyListeners();
      await _saveSeen();
      return;
    }
    if (build <= (_ignoredUpdates[platform] ?? 0)) return;
    _ignoredUpdates[platform] = build;
    notifyListeners();
    await _saveSeen();
  }

  Future<void> _saveSeen() async {
    try {
      await store.change((draft) {
        if (_closed) return;
        draft[seenKey] = {
          'endpoint': _endpoint.toString(),
          if (_announcementMutedContentKey != null &&
              _announcementMutedUntil != null)
            'announcementMute': {
              'contentKey': _announcementMutedContentKey,
              'until': _announcementMutedUntil!.millisecondsSinceEpoch,
            },
          'ignoredUpdates': Map<String, int>.from(_ignoredUpdates),
          if (_ignoredGithubUpdates.isNotEmpty)
            'ignoredGithubUpdates': _ignoredGithubUpdates.toList(),
        };
      });
    } catch (_) {
      DiagnosticLog.event('control.dismiss_save_failed');
    }
  }

  Json diagnostics() => {
    'enabled': enabled,
    'configured': configured,
    'status': statusText,
    'revision': config.revision,
    'cachedRevision': _cached?.revision,
    'cacheFresh': hasFreshConfig,
    'usingCache': usingCache,
    'cachePersisted': cachePersisted,
    'cacheWriteFailed': _saveError != null,
    'checking': checking,
    'lastSuccess': _fetchedAt?.toUtc().toIso8601String(),
    'hasError': lastError != null || _issues.isNotEmpty,
    'lastFailure':
        _lastFailure ?? (_saveError != null ? 'cache_write_failed' : null),
    'errorPath': _errorPath,
    'nextAttempt': _nextAttempt?.toUtc().toIso8601String(),
    'issues': _issues.map((issue) => issue.toJson()).toList(),
    'sections': {
      for (final section in RemoteControlDocument.sectionNames)
        section: {
          'revision': _sectionRevisions[section],
          'lastVerified': _sectionVerifiedAt[section]
              ?.toUtc()
              .toIso8601String(),
          'usingCache':
              _loadedFromCache ||
              _issues.any((issue) => issue.section == section) ||
              _sectionVerifiedAt[section] == null ||
              clock().difference(_sectionVerifiedAt[section]!) >=
                  refreshInterval ||
              (_lastFailure != null && _lastFailure != 'partial_config'),
        },
    },
    'disabledClouds': [
      for (final p in CloudPlatform.values)
        if (!cloudEnabled(p)) p.name,
    ],
  };

  void close() => dispose();

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _cancelTimers();
    _fetcher.close();
    githubUpdates?.close();
    super.dispose();
  }
}
