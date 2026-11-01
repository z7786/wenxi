import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as hashes;
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';
import '../core/json.dart';
import '../core/login_crypto.dart';
import '../domain/resource_search.dart';
import '../domain/models.dart';
import 'client_search_host.dart';
import 'http.dart';
import 'state_store.dart';
import 'sources/host.dart';
import 'sources/package.dart';
import 'sources/runtime.dart';
import 'client_search_key.dart';
import 'client_search_telegram.dart';

typedef SearchManifestFetch = Future<Json> Function(CancelToken token);
typedef ServerSearch =
    Stream<ResourceSearchBatch> Function(
      String keyword,
      List<String> sources,
      CancelToken token,
    );

class ClientSearchEngine {
  ClientSearchEngine({
    required this.store,
    required this.endpoint,
    required this.fetch,
    this.runtime = const SourceRuntime(),
    this.originFetch,
    this.environment,
    this.publicKey = clientSearchPublicKey,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final StateStore store;
  final String endpoint, publicKey;
  final SearchManifestFetch fetch;
  final SourceRuntime runtime;
  final SourceFetch? originFetch;
  final SearchBrowserEnvironment? environment;
  final DateTime Function() clock;
  Json? _manifest;
  final _sessions = <String, ClientSearchSession>{};
  DateTime? _attempt;
  Future<void>? _refresh;
  bool _disabled = false;
  String get _key =>
      'clientSearch:${hashes.sha256.convert(utf8.encode('$endpoint\n$publicKey'))}';
  String get revision => _manifest?.str('revision') ?? '';
  bool get available => _manifest != null && !_disabled;
  bool get disabled => _disabled;
  List<Json> get sources => _manifest?.list('sources') ?? [];

  Json verify(Json envelope) {
    require(
      envelope.str('algorithm') == 'RSA-SHA256' &&
          envelope.str('payload').length <= 16000000,
      '搜索配置格式无效',
    );
    final bytes = base64Decode(envelope.str('payload'));
    final signer = Signer('SHA-256/RSA')
      ..init(
        false,
        PublicKeyParameter<RSAPublicKey>(
          LoginRsa(utf8.decode(base64Decode(publicKey))).key,
        ),
      );
    require(
      signer.verifySignature(
        bytes,
        RSASignature(base64Decode(envelope.str('signature'))),
      ),
      '搜索配置签名校验失败',
    );
    final j = asJson(jsonDecode(utf8.decode(bytes)));
    require(
      j['schema'] == 1 &&
          j['purpose'] == 'asterlink-search' &&
          j.str('revision').length == 64 &&
          j.list('sources').length <= 1000 &&
          j.obj('modules').containsKey('main.js'),
      '搜索配置版本不兼容',
    );
    final ids = <String>{};
    for (final source in j.list('sources')) {
      require(
        ids.add(source.str('id')) &&
            {
              'rule',
              'plugin',
              'catalog',
              'telegram',
              'server',
            }.contains(source.str('kind')),
        '搜索源配置无效',
      );
      if ({'rule', 'plugin'}.contains(source.str('kind'))) package(source, j);
    }
    return j;
  }

  SourcePackage package(Json source, [Json? manifest]) {
    final hosts = source['hosts'] as List? ?? [];
    require(hosts.isNotEmpty, '搜索源缺少请求地址声明');
    return SourcePackage.fromJson({
      'schema': 1,
      'id':
          'search_${source.str('id').replaceAll(RegExp(r'[^a-z0-9_.-]'), '_')}',
      'name': source
          .str('name')
          .substring(0, source.str('name').length.clamp(0, 60)),
      'entry': 'main.js',
      'modules': (manifest ?? _manifest)!.obj('modules'),
      'operations': {
        'search': 'search',
        'resolve': 'resolve',
        'download': 'download',
      },
      'requires': {
        'source': 1,
        'javascript': 1,
        'http': 1,
        'html': 1,
        'crypto': 1,
        'codec': 1,
      },
      'match': [
        {'host': hosts.first, 'pathPrefix': '/'},
      ],
      'permissions': {
        'hosts': hosts,
        'downloadHosts': hosts,
        'schemes': ['http', 'https'],
        'ports': [80, 443],
        'methods': ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'],
        'headers': <String>{
          'Accept',
          'Accept-Language',
          'Content-Type',
          'User-Agent',
          'Referer',
          'Origin',
          'X-Requested-With',
          'X-CSRF-Token',
          'Cookie',
          'X-Pan-So-Visitor-Id',
          'x-tsr-serverFn',
          ..._ruleHeaders(source),
        }.toList(),
      },
      'timeout': source.number('timeout', 15).ceil().clamp(1, 45),
    });
  }

  Set<String> _ruleHeaders(Json source) {
    final names = <String>{};
    names.addAll(source.obj('rule').obj('headers').keys);
    for (final step in source.obj('rule').list('steps')) {
      names.addAll(step.obj('request').obj('headers').keys);
    }
    names.removeWhere(
      (h) => SourcePackage.forbiddenHeaders.contains(h.toLowerCase()),
    );
    return names;
  }

  Future<void> prepare(CancelToken cancellation) async {
    require(!cancellation.isCancelled, '搜索已取消');
    if (_manifest == null) {
      final saved = store.data.obj(_key);
      if (saved['envelope'] is Map) {
        try {
          _manifest = verify(saved.obj('envelope'));
        } catch (_) {}
      }
      _disabled = saved.boolean('disabled') || _manifest?['enabled'] == false;
    }
    final pending = _refresh;
    if (pending != null) {
      await Future.any<void>([
        pending,
        cancellation.whenCancel.then((_) {
          throw const AppException('搜索已取消');
        }),
      ]);
      require(!cancellation.isCancelled, '搜索已取消');
      return;
    }
    if (_attempt != null &&
        clock().difference(_attempt!) < const Duration(minutes: 5)) {
      return;
    }
    _refresh ??= _load(cancellation).whenComplete(() => _refresh = null);
    await _refresh;
  }

  Future<void> _load(CancelToken cancellation) async {
    _attempt = clock();
    try {
      final envelope = await fetch(cancellation);
      require(!cancellation.isCancelled, '搜索已取消');
      final parsed = verify(envelope);
      final prior = revision;
      if (prior != parsed.str('revision')) _sessions.clear();
      _manifest = parsed;
      _disabled = parsed['enabled'] == false;
      await store.change((draft) {
        draft[_key] = {
          'envelope': envelope,
          'disabled': _disabled,
          'results': prior == parsed.str('revision')
              ? draft.obj(_key).obj('results')
              : {},
        };
      });
    } catch (_) {
      if (cancellation.isCancelled) rethrow;
      // Network and invalid updates retain the last authenticated release.
      _attempt = clock().subtract(const Duration(minutes: 4, seconds: 30));
    }
  }

  Stream<ResourceSearchBatch> search(
    String keyword,
    CancelToken cancellation,
    ServerSearch backend,
  ) async* {
    await prepare(cancellation);
    require(!_disabled, '搜索服务暂未开放');
    require(available, '尚未缓存搜索配置，请连接后台完成首次同步');
    final manifest = _manifest!;
    // New manifests flag unlimited results; older manifests retain their cap.
    final limits = manifest.obj('limits');
    final resultLimit = limits.boolean('unlimited_results')
        ? 0
        : limits.integer('result_limit');
    final policy = manifest.obj('policy').obj('sensitive');
    require(
      !(policy.boolean('enabled', true) &&
          policy.boolean('input_enabled', true) &&
          _sensitive(keyword, policy)),
      '搜索关键词不可用',
    );
    final activeIds = sources.map((s) => s.str('id')).toSet();
    final output = <String, ResourceSearchHit>{};
    final rawOutput = <String, Json>{};
    final cachedRows = <String, Json>{};
    final saved = store.data
        .obj(_key)
        .obj('results')
        .obj(keyword.toLowerCase());
    if (saved.str('revision') == revision &&
        clock().millisecondsSinceEpoch - saved.integer('at') <
            const Duration(hours: 24).inMilliseconds) {
      for (final row in saved.list('items')) {
        if (!row.str('client_source_id').startsWith('server') &&
            row.str('client_source_id').isNotEmpty &&
            !activeIds.contains(row.str('client_source_id'))) {
          continue;
        }
        try {
          final hit = ResourceSearchHit.fromRaw(row);
          output[hit.identity] = hit;
          cachedRows[hit.identity] = row;
        } catch (_) {}
      }
      if (output.isNotEmpty) yield ResourceSearchBatch(output.values.toList());
    }
    final fresh = <String, ResourceSearchHit>{};
    final controller = StreamController<List<Json>>();
    final scope = RequestScope();
    final cancel = cancellation.whenCancel.asStream().listen(
      (_) => scope.cancel(),
    );
    if (cancellation.isCancelled) scope.cancel();
    final timer = Timer(
      Duration(
        seconds: manifest
            .obj('limits')
            .integer('total_timeout', 45)
            .clamp(5, 60),
      ),
      scope.cancel,
    );
    var healthy = 0;
    final succeeded = <String>{};
    final localSorted = sources.where((s) => s.str('kind') != 'server').toList()
      ..sort((a, b) => b.integer('priority').compareTo(a.integer('priority')));
    final groups = [
      for (final kind in ['rule', 'plugin', 'catalog', 'telegram'])
        localSorted.where((s) => s.str('kind') == kind).toList(),
    ];
    final local = <Json>[];
    while (groups.any((g) => g.isNotEmpty)) {
      for (final group in groups) {
        if (group.isNotEmpty) local.add(group.removeAt(0));
      }
    }
    final failed = <String>[];
    final fallbackSignal = StreamController<void>();
    var telegramFailures = 0;
    final serverIds = sources
        .where((s) => s.str('kind') == 'server')
        .map((s) => s.str('id'))
        .toList();
    var next = 0;
    Future<void> worker() async {
      while (next < local.length && !scope.token.isCancelled) {
        final source = local[next++];
        if (source.str('kind') == 'telegram' && telegramFailures >= 3) {
          failed.add(source.str('id'));
          if (!fallbackSignal.isClosed) fallbackSignal.add(null);
          continue;
        }
        try {
          final rows = await scope.run(() => _one(source, keyword, manifest));
          healthy++;
          succeeded.add(source.str('id'));
          if (!controller.isClosed) {
            controller.add([
              for (final r in rows)
                {...r, 'client_source_id': source.str('id')},
            ]);
          }
        } catch (_) {
          if (!scope.token.isCancelled) {
            if (source.str('kind') == 'telegram') telegramFailures++;
            failed.add(source.str('id'));
            if (!fallbackSignal.isClosed) fallbackSignal.add(null);
          }
        }
      }
    }

    Future<void> server(List<String> ids, {bool initial = false}) async {
      final cacheId = initial
          ? 'server'
          : 'server:fallback:${(ids.toList()..sort()).join(',')}';
      var complete = false;
      try {
        await for (final batch in backend(keyword, ids, scope.token)) {
          complete = complete || batch.complete;
          if (!controller.isClosed) {
            controller.add(
              batch.items
                  .map((h) => {..._rawHit(h), 'client_source_id': cacheId})
                  .toList(),
            );
          }
        }
        if (complete) {
          healthy++;
          succeeded.add(cacheId);
        }
      } catch (_) {
        /* Direct searches remain useful without the backend. */
      }
    }

    Future<void> fallback() async {
      try {
        await for (final _ in fallbackSignal.stream) {
          if (scope.token.isCancelled) break;
          if (failed.isEmpty) continue;
          await RequestScope.cancellable(
            Future<void>.delayed(const Duration(milliseconds: 400)),
          );
          while (failed.isNotEmpty && !scope.token.isCancelled) {
            final count = failed.length.clamp(1, 200);
            final ids = failed.sublist(0, count);
            failed.removeRange(0, count);
            await server(ids);
          }
        }
      } catch (_) {
        /* Cancellation leaves partial local results usable. */
      }
    }

    final workers = [
      for (
        var i = 0;
        i < manifest.obj('limits').integer('workers', 4).clamp(1, 6);
        i++
      )
        worker(),
    ];
    final tasks = [
      server(serverIds, initial: true),
      fallback(),
      Future.wait(workers).whenComplete(() => fallbackSignal.close()),
    ];
    unawaited(Future.wait(tasks).whenComplete(() => controller.close()));
    try {
      await for (final rows in controller.stream) {
        require(!cancellation.isCancelled, '搜索已停止');
        for (final raw in rows) {
          final row = _normalize(raw, keyword);
          if (row == null) continue;
          try {
            final hit = ResourceSearchHit.fromRaw(row);
            if (!{
              LinkKind.cloudShare,
              LinkKind.magnet,
              LinkKind.torrent,
              LinkKind.ed2k,
            }.contains(hit.link?.kind)) {
              continue;
            }
            if (resultLimit > 0 &&
                fresh.length >= resultLimit &&
                !fresh.containsKey(hit.identity)) {
              continue;
            }
            fresh[hit.identity] = fresh[hit.identity]?.merge(hit) ?? hit;
            output[hit.identity] = output[hit.identity]?.merge(hit) ?? hit;
            rawOutput[hit.identity] = row;
          } catch (_) {}
        }
        yield ResourceSearchBatch(
          (resultLimit > 0 ? output.values.take(resultLimit) : output.values)
              .toList(),
        );
      }
      require(!cancellation.isCancelled, '搜索已停止');
      for (final entry in cachedRows.entries) {
        if (succeeded.contains(entry.value.str('client_source_id'))) {
          output.remove(entry.key);
        } else {
          rawOutput.putIfAbsent(entry.key, () => entry.value);
        }
      }
      output.addAll(fresh);
      if (healthy > 0) {
        await store.change((draft) {
          final state = draft.obj(_key), results = state.obj('results');
          results[keyword.toLowerCase()] = {
            'at': clock().millisecondsSinceEpoch,
            'revision': manifest.str('revision'),
            'items':
                (resultLimit > 0
                        ? rawOutput.values.take(resultLimit)
                        : rawOutput.values)
                    .toList(),
          };
          while (results.length > 12) {
            results.remove(results.keys.first);
          }
          draft[_key] = {...state, 'results': results};
        });
      }
      if (healthy == 0 && output.isEmpty) {
        throw const AppException('当前网络无法连接搜索源，缓存中也没有这个关键词的结果');
      }
      yield ResourceSearchBatch(
        (resultLimit > 0 ? output.values.take(resultLimit) : output.values)
            .toList(),
        complete: true,
      );
    } finally {
      timer.cancel();
      scope.cancel();
      await cancel.cancel();
    }
  }

  Future<List<Json>> _one(Json source, String keyword, Json manifest) async {
    if (source.str('kind') == 'catalog') {
      final rows = source.list('records'),
          terms = keyword.toLowerCase().split(RegExp(r'\s+'));
      return rows
          .where(
            (r) => terms.every(
              (t) =>
                  '${r.str('title', r.str('t'))} ${r.str('category', r.str('c'))}'
                      .toLowerCase()
                      .contains(t),
            ),
          )
          .take(source.integer('limit', 50))
          .map(
            (r) => {
              'title': r.str('title', r.str('t')),
              'url': r.str('share_link', r.str('u')),
              'password': r.str('password'),
              'description': r.str('category'),
            },
          )
          .toList();
    }
    if (source.str('kind') == 'telegram') return _telegram(source, keyword);
    final package = this.package(source, manifest);
    final session = _sessions.putIfAbsent(
      source.str('id'),
      ClientSearchSession.new,
    );
    final cached = session.results[keyword];
    if (cached != null && cached.$1.isAfter(clock())) return cached.$2;
    final host = ClientSearchHost(
      package,
      fetch: originFetch,
      environment: environment,
      session: session,
    );
    try {
      final result = await runtime.run(package, 'search', {
        'source': source,
        'keyword': keyword,
        'uuid': await host.call('visitor', {}),
      }, host.call);
      final rows = result.list('results');
      require(rows.isNotEmpty || host.failedRequests == 0, '搜索源请求失败');
      final ttl = source.str('kind') == 'rule'
          ? source.obj('rule').integer('cache_ttl', 180)
          : 180;
      if (ttl > 0) {
        while (session.results.length >= 12) {
          session.results.remove(session.results.keys.first);
        }
        session.results[keyword] = (
          clock().add(Duration(seconds: rows.isEmpty ? ttl.clamp(0, 30) : ttl)),
          rows,
        );
      }
      return rows;
    } finally {
      await host.close();
    }
  }

  Future<List<Json>> _telegram(Json source, String keyword) async {
    final package = SourcePackage.fromJson({
      'schema': 1,
      'id': 'search_tg',
      'name': '频道搜索',
      'requires': {'source': 1, 'javascript': 1, 'http': 1, 'html': 1},
      'entry': 'main.js',
      'modules': {
        'main.js': 'export function resolve(){} export function download(){}',
      },
      'operations': {'resolve': 'resolve', 'download': 'download'},
      'match': [
        {'host': 't.me'},
      ],
      'permissions': {
        'hosts': ['t.me'],
        'downloadHosts': ['t.me'],
        'headers': ['Accept', 'User-Agent'],
        'methods': ['GET'],
      },
      'timeout': 10,
    });
    final host = ClientSearchHost(package, fetch: originFetch);
    try {
      final response = asJson(
        await host.call('request', {
          'url': query('https://t.me/s/${source.str('channel')}', {
            'q': keyword,
          }),
          'timeout': 8,
          'redirects': false,
        }),
      );
      final rows = objects(
        await host.call('telegram', {'text': response.str('text')}),
      );
      require(response.integer('status') == 200, '频道连接失败');
      return rows.expand(parseClientTelegram).toList();
    } finally {
      await host.close();
    }
  }

  Json? _normalize(Json row, String keyword) {
    String first(List<String> names) => names
        .map((k) => row.str(k))
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    final url = first([
      'url',
      'share_link',
      'link',
      'share_url',
      'original_url',
      'viewlink',
      'data_url',
      'downurl',
      'vod_play_url',
    ]);
    if (url.isEmpty) return null;
    final found = RegExp(
      r'https?://[^\s<>"，。；]+|magnet:\?[^\s<>]+|ed2k://[^\s<>]+',
    ).firstMatch(url);
    if (found == null) return null;
    final normalized = <String, dynamic>{
      ...row,
      'url': found[0]!.replaceAll(RegExp(r'[.,;，。；、)]+$'), ''),
      'pool_supported': (_manifest!['pool_hosts'] as List? ?? []).contains(
        Uri.tryParse(found[0]!)?.host,
      ),
      'title': first([
        'title',
        'name',
        'note',
        'filename',
        'disk_name',
        'vod_name',
      ]).ifEmpty(keyword),
      'password': first([
        'password',
        'pwd',
        'share_pwd',
        'passcode',
        'code',
        'disk_pass',
        'extcode',
        'unzipcode',
        'vod_pwd',
        'crux',
      ]),
      'cover_url': first([
        'cover_url',
        'cover',
        'image',
        'thumbnail',
        'pic',
        'poster',
      ]),
      'description': first([
        'description',
        'desc',
        'content',
        'summary',
        'intro',
      ]),
      'datetime': first([
        'datetime',
        'updated_at',
        'created_at',
        'time',
        'date',
      ]),
    };
    final policy = _manifest!.obj('policy');
    final sensitive = policy.obj('sensitive');
    final title = normalized.str('title').toLowerCase();
    if (sensitive.boolean('enabled', true) &&
        sensitive.boolean('output_enabled', true) &&
        _sensitive('$title ${normalized.str('url')}', sensitive)) {
      return null;
    }
    final ads = policy.obj('ads');
    if (ads.boolean('enabled') &&
        (ads['keywords'] as List? ?? []).whereType<String>().any(
          (s) => s.isNotEmpty && title.contains(s.toLowerCase()),
        )) {
      return null;
    }
    if (policy.str('title_filter_mode') == 'strict' &&
        !keyword.toLowerCase().split(RegExp(r'\s+')).every(title.contains)) {
      return null;
    }
    if (policy.str('title_filter_mode') == 'loose' &&
        !keyword.toLowerCase().split(RegExp(r'\s+')).any(title.contains)) {
      final chars = keyword
          .toLowerCase()
          .split('')
          .where((c) => c.trim().isNotEmpty)
          .toSet();
      if (chars.isNotEmpty &&
          chars.where(title.contains).length / chars.length < .4) {
        return null;
      }
    }
    return normalized;
  }

  bool _sensitive(String text, Json policy) => (policy['words'] as List? ?? [])
      .whereType<String>()
      .any((s) => s.isNotEmpty && text.toLowerCase().contains(s.toLowerCase()));

  Json _rawHit(ResourceSearchHit hit) => {
    'title': hit.title,
    'url': hit.url,
    'password': hit.password,
    'description': hit.description,
    'cover_url': hit.coverUrl,
    'datetime': hit.date,
    'open_ticket': hit.openTicket,
    'pool_supported': hit.poolSupported,
  };
}
