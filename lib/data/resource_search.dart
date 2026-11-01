import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../domain/resource_search.dart';
import '../domain/models.dart';
import 'resource_search_api.dart';
import 'resource_link_checks.dart';
import 'state_store.dart';
import 'http.dart';

enum ResourceSearchPhase {
  idle,
  searching,
  checking,
  complete,
  stopped,
  failed,
}

class ResourceSearch extends ChangeNotifier {
  ResourceSearch({
    required this.store,
    required this.api,
    this.linkChecks,
    this.clock = DateTime.now,
    this.budget = const Duration(seconds: 70),
    this.publishDelay = const Duration(milliseconds: 250),
  }) {
    linkChecks?.addListener(_checksChanged);
  }
  final StateStore store;
  final ResourceSearchApi api;
  final ResourceLinkChecks? linkChecks;
  final DateTime Function() clock;
  final Duration budget, publishDelay;
  ResourceSearchPhase phase = ResourceSearchPhase.idle;
  String keyword = '', error = '';
  String? cloudFilter;
  List<String> includeTerms = const [], excludeTerms = const [];
  bool get hasKeywordFilters =>
      includeTerms.isNotEmpty || excludeTerms.isNotEmpty;
  final _hits = <String, ResourceSearchHit>{};
  final _published = <String, ResourceSearchHit>{};
  final _cache = <String, (DateTime, List<ResourceSearchHit>)>{};
  final _healthSnapshot = <String, ResourceLinkHealth>{};
  final _healthRanks = <String, int>{};
  ResourceLinkCheckBatch? _checkBatch;
  CancelToken? _cancellation;
  Timer? _deadline;
  Timer? _publication;
  int _generation = 0, _resultGeneration = 0;
  bool _closed = false;
  bool fromCache = false;
  List<ResourceSearchHit> recommendations = const [];
  bool recommendationsLoading = false, recommendationsLoaded = false;
  String recommendationsError = '';
  int _recommendationGeneration = 0;
  Future<void>? _recommendationRequest;
  final _discoveryScope = RequestScope();
  Future<void>? _preloading;
  DateTime? _preloadAttempt;
  ResourceCatalog catalog = const ResourceCatalog();
  bool catalogLoaded = false;
  String catalogError = '';
  final catalogLoading = <String>{};
  int catalogRevision = 0;
  final _catalogRequests = <String, Future<void>>{};
  int _catalogGeneration = 0;

  Future<void> preload() {
    if (_closed) return Future.value();
    if (_preloading != null) return _preloading!;
    if (_preloadAttempt != null &&
        !clock().isBefore(_preloadAttempt!) &&
        clock().difference(_preloadAttempt!) < const Duration(minutes: 5)) {
      return Future.value();
    }
    _preloadAttempt = clock();
    return _preloading = _preload().whenComplete(() => _preloading = null);
  }

  Future<void> _preload() async {
    var configurationFailed = false;
    Future<void> configuration() async {
      final client = api;
      if (client is! ResourceSearchConfigurationApi) return;
      try {
        // This token belongs to the service; stopping a search leaves it alive.
        await _discoveryScope.run(
          () => RequestScope.cancellable(
            (client as ResourceSearchConfigurationApi).prepareSources(
              _discoveryScope.token,
            ),
          ),
          inheritGuard: false,
        );
      } catch (_) {
        configurationFailed = true;
      }
    }

    await Future.wait([
      configuration(),
      loadRecommendations(force: true),
      loadCatalog(refresh: true),
    ]);
    if (!_closed &&
        (configurationFailed ||
            catalogError.isNotEmpty ||
            recommendationsError.isNotEmpty)) {
      _preloadAttempt = clock().subtract(
        const Duration(minutes: 4, seconds: 30),
      );
    }
  }

  Future<void> loadRecommendations({bool refresh = false, bool force = false}) {
    if (_closed) return Future.value();
    if (_recommendationRequest != null) return _recommendationRequest!;
    if ((recommendationsLoaded && !refresh && !force) ||
        api is! ResourceDiscoveryApi) {
      return Future.value();
    }
    return _recommendationRequest = _loadRecommendations(
      refresh: refresh,
    ).whenComplete(() => _recommendationRequest = null);
  }

  Future<void> _loadRecommendations({required bool refresh}) async {
    final client = api;
    final generation = ++_recommendationGeneration;
    recommendationsLoading = true;
    recommendationsError = '';
    notifyListeners();
    try {
      final rows = await _discoveryScope.run(
        () => RequestScope.cancellable(
          (client as ResourceDiscoveryApi).recommendations(
            exclude: refresh
                ? recommendations
                      .map((r) => r.recommendationId)
                      .where((id) => id > 0)
                      .toList()
                : const [],
            refresh: refresh,
          ),
        ),
        inheritGuard: false,
      );
      if (_closed || generation != _recommendationGeneration) return;
      recommendations = List.unmodifiable(rows);
      recommendationsLoaded = true;
    } catch (_) {
      if (_closed || generation != _recommendationGeneration) return;
      recommendationsError = '推荐资源暂时加载失败，点击重试';
    } finally {
      if (!_closed && generation == _recommendationGeneration) {
        recommendationsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadCatalog({String section = '', bool refresh = false}) {
    if (_closed) return Future.value();
    final pending = _catalogRequests[''] ?? _catalogRequests[section];
    if (pending != null) return pending;
    if (section.isEmpty && catalogLoaded && !refresh) return Future.value();
    return _catalogRequests[section] = _loadCatalog(section).whenComplete(() {
      _catalogRequests.remove(section);
    });
  }

  Future<void> _loadCatalog(String section) async {
    final generation = section.isEmpty
        ? ++_catalogGeneration
        : _catalogGeneration;
    catalogLoading.add(section);
    catalogError = '';
    catalogRevision++;
    notifyListeners();
    try {
      final client = api;
      final old = section == 'popular'
          ? catalog.popular
          : catalog.categories
                    .where((c) => '${c.id}' == section)
                    .firstOrNull
                    ?.resources ??
                <ResourceSearchHit>[];
      final exclude = old
          .map((r) => r.recommendationId)
          .where((id) => id > 0)
          .toList();
      final next = await _discoveryScope.run(() async {
        if (client is ResourceCatalogApi) {
          return RequestScope.cancellable(
            (client as ResourceCatalogApi).catalog(
              refreshSection: section,
              exclude: exclude,
            ),
          );
        }
        if (client is ResourceDiscoveryApi) {
          if (section.isEmpty) {
            await loadRecommendations();
            require(recommendationsError.isEmpty, recommendationsError);
            return ResourceCatalog(popular: recommendations);
          }
          return ResourceCatalog(
            popular: await RequestScope.cancellable(
              (client as ResourceDiscoveryApi).recommendations(
                refresh: true,
                exclude: exclude,
              ),
            ),
          );
        }
        return const ResourceCatalog();
      }, inheritGuard: false);
      if (_closed || generation != _catalogGeneration) return;
      catalogLoaded = true;
      if (section.isEmpty) {
        catalog = next;
      } else if (section == 'popular') {
        catalog = ResourceCatalog(
          popular: next.popular,
          categories: catalog.categories,
        );
      } else {
        final replacement = next.categories
            .where((c) => '${c.id}' == section)
            .firstOrNull;
        catalog = ResourceCatalog(
          popular: catalog.popular,
          categories: [
            for (final category in catalog.categories)
              if ('${category.id}' != section) category else ?replacement,
          ],
        );
      }
    } catch (_) {
      if (!_closed && generation == _catalogGeneration) {
        catalogError = '资源暂时加载失败，请稍后重试';
      }
    } finally {
      catalogLoading.remove(section);
      catalogRevision++;
      if (!_closed) notifyListeners();
    }
  }

  bool get searching =>
      phase == ResourceSearchPhase.searching ||
      phase == ResourceSearchPhase.checking;
  bool get checking => phase == ResourceSearchPhase.checking;
  int get checkTotal => _checkBatch?.totalCount ?? 0;
  int get checkCompleted => _checkBatch?.checkedCount ?? 0;
  int get resultGeneration => _resultGeneration;
  bool get checksPaused => _checkBatch?.paused ?? false;
  void pauseChecks() => _checkBatch?.pause();
  void resumeChecks() => _checkBatch?.resume();

  void _checksChanged() {
    if (_closed) return;
    if (_checkBatch != null) {
      _schedulePublication();
      notifyListeners();
    } else if (linkChecks case final checks?) {
      for (final hit in _hits.values) {
        final current = checks.health(hit);
        if (current.settled && current.checkedAt != null) {
          _healthSnapshot[resourceLinkKey(hit)] = current;
        }
      }
    }
  }

  ResourceLinkHealth? health(ResourceSearchHit hit) {
    final checks = linkChecks;
    if (checks == null) return null;
    final current = checks.health(hit);
    return current.state == ResourceLinkState.checking ||
            current.checkedAt != null
        ? current
        : _healthSnapshot[resourceLinkKey(hit)] ?? current;
  }

  ResourceSearchHit currentHit(ResourceSearchHit hit) =>
      _hits[hit.identity] ?? hit;

  bool get preferSupported =>
      store.data.obj('resourceSearch').boolean('preferSupported', true);
  List<String> get history =>
      (store.data['resourceSearchHistory'] as List? ?? [])
          .whereType<String>()
          .where((e) => e.length <= 120)
          .take(12)
          .toList();
  List<ResourceSearchHit> get allItems => List.unmodifiable(_hits.values);
  static const defaultCloudPriority = [
    CloudPlatform.quark,
    CloudPlatform.uc,
    CloudPlatform.tianyi,
    CloudPlatform.c139,
    CloudPlatform.wopan,
    CloudPlatform.guangya,
    CloudPlatform.xunlei,
    CloudPlatform.pan115,
    CloudPlatform.weiyun,
    CloudPlatform.pikpak,
    CloudPlatform.baidu,
    CloudPlatform.aliyun,
    CloudPlatform.pan123,
    CloudPlatform.lanzou,
    CloudPlatform.ilanzou,
    CloudPlatform.ctfile,
    CloudPlatform.feijipan,
    CloudPlatform.github,
  ];
  List<CloudPlatform> get cloudPriority {
    final saved = store.data.obj('resourceSearch')['cloudPriority'];
    return [
      ...{
        if (saved is List)
          ...saved.whereType<String>().map(CloudPlatform.fromKey).nonNulls,
        ...defaultCloudPriority,
      },
    ];
  }

  Future<void> setCloudPriority(List<CloudPlatform> values) async {
    final order = {
      ...values,
      ...defaultCloudPriority,
    }.map((p) => p.key).toList();
    await store.change((draft) {
      draft['resourceSearch'] = draft.obj('resourceSearch')
        ..['cloudPriority'] = order;
    });
    linkChecks?.clearVisible();
    if (!_closed) notifyListeners();
  }

  List<String> get orderedClouds {
    final names = allItems.map((hit) => hit.cloudName).toSet();
    return [
      for (final platform in cloudPriority)
        if (names.remove(platform.label)) platform.label,
      ...(names.toList()..sort()),
    ];
  }

  List<ResourceSearchHit> get items {
    final source = linkChecks == null ? _hits.values : _published.values;
    final values = source.where((hit) {
      final title = hit.title.toLowerCase();
      return (cloudFilter == null || hit.cloudName == cloudFilter) &&
          includeTerms.every((term) => title.contains(term.toLowerCase())) &&
          !excludeTerms.any((term) => title.contains(term.toLowerCase()));
    }).toList();
    final ranks = {
      for (final (index, platform) in cloudPriority.indexed) platform: index,
    };
    final original = {
      for (final (index, hit) in _hits.values.indexed) hit.identity: index,
    };
    values.sort((a, b) {
      final healthRank = (_healthRanks[resourceLinkKey(a)] ?? 1).compareTo(
        _healthRanks[resourceLinkKey(b)] ?? 1,
      );
      if (healthRank != 0) return healthRank;
      final rank = (ranks[a.platform] ?? ranks.length).compareTo(
        ranks[b.platform] ?? ranks.length,
      );
      if (rank != 0) return rank;
      if (preferSupported && a.canParse != b.canParse) {
        return a.canParse ? -1 : 1;
      }
      return original[a.identity]!.compareTo(original[b.identity]!);
    });
    return values;
  }

  void filter(String? value) {
    linkChecks?.clearVisible();
    cloudFilter = value;
    notifyListeners();
  }

  void setKeywordFilters({String include = '', String exclude = ''}) {
    linkChecks?.clearVisible();
    List<String> terms(String text) => text
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toSet()
        .toList(growable: false);
    includeTerms = terms(include);
    excludeTerms = terms(exclude);
    notifyListeners();
  }

  Future<void> setPreferSupported(bool value) async {
    await store.change((draft) {
      draft['resourceSearch'] = draft.obj('resourceSearch')
        ..['preferSupported'] = value;
    });
    if (!_closed) notifyListeners();
  }

  Future<void> clearHistory() async {
    await store.change((draft) => draft.remove('resourceSearchHistory'));
    if (!_closed) notifyListeners();
  }

  Future<void> search(String query, {bool refresh = false}) async {
    final term = query.trim();
    if (_closed) return;
    if (term.runes.length < 2 || term.length > 120) {
      _cancelChecks();
      linkChecks?.clearVisible();
      _deadline?.cancel();
      _generation++;
      _resultGeneration++;
      _cancellation?.cancel();
      _cancellation = null;
      keyword = term;
      phase = ResourceSearchPhase.failed;
      _hits.clear();
      _published.clear();
      _healthSnapshot.clear();
      _healthRanks.clear();
      error = '请输入 2–120 个字符的关键词';
      notifyListeners();
      return;
    }
    if (searching && term == keyword && !refresh) return;
    _cancelChecks();
    linkChecks?.clearVisible();
    _cancellation?.cancel();
    _deadline?.cancel();
    final generation = ++_generation, cancellation = CancelToken();
    _resultGeneration++;
    _cancellation = cancellation;
    keyword = term;
    error = '';
    fromCache = false;
    _hits.clear();
    _published.clear();
    _healthSnapshot.clear();
    _healthRanks.clear();
    phase = ResourceSearchPhase.searching;
    _checkBatch = linkChecks?.beginBatch();
    notifyListeners();
    // Search history stays in the app's encrypted local state.
    unawaited(
      store
          .change((draft) {
            final recent = (draft['resourceSearchHistory'] as List? ?? [])
                .whereType<String>();
            draft['resourceSearchHistory'] = [
              term,
              ...recent.where((e) => e.toLowerCase() != term.toLowerCase()),
            ].take(12).toList();
          })
          .catchError((Object _) {}),
    );
    final cached = _cache[term.toLowerCase()];
    if (!refresh &&
        !(api is HttpResourceSearchApi &&
            (api as HttpResourceSearchApi).clientSearch != null) &&
        cached != null &&
        clock().difference(cached.$1) < const Duration(minutes: 2)) {
      _merge(cached.$2);
      fromCache = true;
      _updateChecks();
      await _finishChecks(generation);
      if (_closed || generation != _generation) return;
      phase = ResourceSearchPhase.complete;
      cancellation.cancel('finished');
      _cancellation = null;
      notifyListeners();
      return;
    }
    final deadline = Timer(budget, () {
      if (_closed ||
          generation != _generation ||
          phase != ResourceSearchPhase.searching) {
        return;
      }
      _publishStoppedChecks();
      phase = ResourceSearchPhase.failed;
      error = '搜索耗时较长，已找到的结果已保留';
      _generation++;
      cancellation.cancel('deadline');
      _cancellation = null;
      notifyListeners();
    });
    _deadline = deadline;
    var targetPhase = ResourceSearchPhase.complete;
    var receivedComplete = false;
    try {
      await for (final batch in api.search(term, cancellation)) {
        if (_closed || generation != _generation) return;
        if (batch.complete) {
          deadline.cancel();
          final previous = Map<String, ResourceSearchHit>.of(_hits);
          _hits.clear();
          _merge(
            batch.items
                .map((hit) => previous[hit.identity]?.merge(hit) ?? hit)
                .toList(),
          );
        } else {
          _merge(batch.items);
        }
        _updateChecks();
        if (batch.complete) {
          receivedComplete = true;
          phase = linkChecks != null
              ? ResourceSearchPhase.checking
              : ResourceSearchPhase.complete;
          _cache[term.toLowerCase()] = (clock(), allItems);
          while (_cache.length > 12) {
            _cache.remove(_cache.keys.first);
          }
        }
        notifyListeners();
        if (batch.complete) break;
      }
      if (!_closed && generation == _generation && !receivedComplete) {
        targetPhase = ResourceSearchPhase.failed;
        error = '搜索连接已断开，已找到的结果已保留';
      }
    } catch (e) {
      if (_closed || generation != _generation) return;
      targetPhase = ResourceSearchPhase.failed;
      error = e is AppException ? e.message : '搜索暂时不可用，请检查网络后重试';
    } finally {
      deadline.cancel();
    }
    if (_closed || generation != _generation) return;
    await _finishChecks(generation);
    if (!_closed && generation == _generation) {
      phase = targetPhase;
      cancellation.cancel('finished');
      _cancellation = null;
      notifyListeners();
    }
  }

  void _updateChecks() {
    _published.removeWhere((identity, _) => !_hits.containsKey(identity));
    _checkBatch?.update(_hits.values);
  }

  Future<void> _finishChecks(int generation) async {
    final batch = _checkBatch;
    if (batch != null) {
      phase = ResourceSearchPhase.checking;
      notifyListeners();
      await batch.finish();
      if (_closed || generation != _generation || _checkBatch != batch) return;
      _publishReady();
      _checkBatch = null;
    }
  }

  void _schedulePublication() {
    final batch = _checkBatch;
    if (batch == null) return;
    final ready = batch.results;
    final waiting = _hits.values
        .where(
          (hit) =>
              ready.containsKey(resourceLinkKey(hit)) &&
              !identical(_published[hit.identity], hit),
        )
        .length;
    if (waiting >= 15) {
      _publishReady();
    } else if (waiting > 0) {
      _publication ??= Timer(publishDelay, () {
        _publication = null;
        if (_closed || _checkBatch != batch) return;
        _publishReady();
        notifyListeners();
      });
    }
  }

  void _publishReady({bool includeUnchecked = false}) {
    _publication?.cancel();
    _publication = null;
    final results =
        _checkBatch?.results ?? const <String, ResourceLinkHealth>{};
    _published.removeWhere((identity, _) => !_hits.containsKey(identity));
    for (final hit in _hits.values) {
      final key = resourceLinkKey(hit);
      final checked = results[key];
      if (checked == null && !includeUnchecked) continue;
      final result =
          checked ??
          const ResourceLinkHealth(
            ResourceLinkState.unknown,
            message: '检测已停止，可打开分享或手动重新检测。',
          );
      _healthSnapshot[key] = result;
      _healthRanks.putIfAbsent(key, () => result.sortRank);
      _published[hit.identity] = hit;
    }
  }

  void _publishStoppedChecks() {
    final batch = _checkBatch;
    if (batch == null) return;
    _publishReady(includeUnchecked: true);
    _cancelChecks();
  }

  void _cancelChecks() {
    _publication?.cancel();
    _publication = null;
    final batch = _checkBatch;
    _checkBatch = null;
    batch?.cancel();
  }

  void _merge(List<ResourceSearchHit> items) {
    for (final hit in items) {
      final previous = _hits[hit.identity];
      if (previous != null) {
        _hits[hit.identity] = previous.merge(hit);
      } else {
        _hits[hit.identity] = hit;
      }
    }
  }

  void stop() {
    if (!searching || _closed) return;
    _publishStoppedChecks();
    _generation++;
    _deadline?.cancel();
    _cancellation?.cancel();
    _cancellation = null;
    phase = ResourceSearchPhase.stopped;
    error = '';
    notifyListeners();
  }

  void showRecommendations() {
    stop();
    _resultGeneration++;
    keyword = '';
    phase = ResourceSearchPhase.idle;
    error = '';
    _hits.clear();
    _published.clear();
    _healthSnapshot.clear();
    _healthRanks.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _discoveryScope.cancel();
    _cancelChecks();
    linkChecks?.removeListener(_checksChanged);
    linkChecks?.dispose();
    _deadline?.cancel();
    _generation++;
    _cancellation?.cancel();
    super.dispose();
  }
}
