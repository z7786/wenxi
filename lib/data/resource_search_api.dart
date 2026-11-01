import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../core/json.dart';
import '../domain/resource_search.dart';
import 'http.dart';
import 'state_store.dart';
import '../core/crypto_box.dart';
import 'search_security.dart';
import 'client_search_engine.dart';
import '../domain/backend_endpoints.dart';
import 'client_search_host.dart';

abstract interface class ResourceDiscoveryApi {
  Future<List<ResourceSearchHit>> recommendations({
    List<int> exclude = const [],
    bool refresh = false,
  });
}

abstract interface class ResourceCatalogApi {
  Future<ResourceCatalog> catalog({
    String refreshSection = '',
    List<int> exclude = const [],
  });
}

abstract interface class ResourceSearchConfigurationApi {
  Future<void> prepareSources(CancelToken cancellation);
}

abstract interface class ResourceSearchApi {
  Stream<ResourceSearchBatch> search(String keyword, CancelToken cancellation);
  Future<ResourceSearchOpenResult> open(
    ResourceSearchHit hit,
    CancelToken cancellation, {
    required ResourceSearchFileSelection selection,
  });
}

class HttpResourceSearchApi
    implements
        ResourceSearchApi,
        ResourceDiscoveryApi,
        ResourceCatalogApi,
        ResourceSearchConfigurationApi {
  HttpResourceSearchApi(
    this.http, {
    String endpoint = buildUrl,
    this.store,
    bool localSearch = false,
    SearchBrowserEnvironment? browserEnvironment,
  }) : endpoint = endpoint.replaceFirst(RegExp(r'/+$'), ''),
       security = SearchSecurityClient(
         http,
         endpoint.replaceFirst(RegExp(r'/+$'), ''),
       ) {
    if (localSearch && store != null) {
      clientSearch = ClientSearchEngine(
        store: store!,
        endpoint: this.endpoint,
        fetch: _manifest,
        environment: browserEnvironment,
      );
    }
  }
  static const buildUrl = String.fromEnvironment(
    'RESOURCE_SEARCH_URL',
    defaultValue: BackendEndpoints.search,
  );
  final JsonHttp http;
  final String endpoint;
  final StateStore? store;
  final SearchSecurityClient security;
  ClientSearchEngine? clientSearch;
  String get configurationRevision => clientSearch?.revision ?? '';
  @override
  Future<void> prepareSources(CancelToken token) async {
    await clientSearch?.prepare(token);
  }

  String? _clientId;

  Future<String> _identity() async {
    if (_clientId != null) return _clientId!;
    final saved = store?.data.str('resourceClientId') ?? '';
    _clientId = RegExp(r'^[a-f0-9]{32}$').hasMatch(saved)
        ? saved
        : CryptoBox.random(
            16,
          ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (store != null && saved != _clientId) {
      await store!.change((data) => data['resourceClientId'] = _clientId);
    }
    return _clientId!;
  }

  @override
  Future<List<ResourceSearchHit>> recommendations({
    List<int> exclude = const [],
    bool refresh = false,
  }) async {
    final response = await http.get(
      query('$endpoint/api/v1/resources/recommendations', {
        if (exclude.isNotEmpty) 'exclude': exclude.take(24).join(','),
        if (refresh) 'refresh': '1',
      }),
    );
    require(response.body.length <= 512 * 1024, '推荐内容响应过大');
    final value = _json(response.body);
    _checkStatus(response.status, value);
    return ResourceSearchBatch.fromJson(value).items;
  }

  @override
  Future<ResourceCatalog> catalog({
    String refreshSection = '',
    List<int> exclude = const [],
  }) async {
    final response = await http.get(
      query('$endpoint/api/v1/resources/catalog', {
        if (refreshSection.isNotEmpty) 'refresh_section': refreshSection,
        if (exclude.isNotEmpty) 'exclude': exclude.take(24).join(','),
      }),
    );
    if (response.status == 404) {
      return ResourceCatalog(
        popular: await recommendations(
          exclude: exclude,
          refresh: refreshSection.isNotEmpty,
        ),
      );
    }
    require(response.body.length <= 4 * 1024 * 1024, '资源内容响应过大');
    final value = _json(response.body);
    _checkStatus(response.status, value);
    return ResourceCatalog.fromJson(value);
  }

  String _url(String path, String keyword) => query('$endpoint/api/v1/$path', {
    'keyword': keyword,
    'scope': 'all',
    'limit': 0,
    'format': 'object',
  });

  @override
  Future<ResourceSearchOpenResult> open(
    ResourceSearchHit hit,
    CancelToken cancellation, {
    required ResourceSearchFileSelection selection,
  }) async {
    if (_backendDownUntil != null &&
        DateTime.now().isBefore(_backendDownUntil!)) {
      require(!cancellation.isCancelled, '打开已取消');
      return _original(hit);
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _openOnce(hit, cancellation, selection: selection);
      } on SearchVerificationRequired {
        if (attempt != 0) rethrow;
        try {
          await security.ensure(cancellation);
        } on HttpRequestFailure catch (e) {
          if (!cancellation.isCancelled && e.retryable) return _original(hit);
          rethrow;
        }
      } on _BackendUnavailable {
        require(!cancellation.isCancelled, '打开已取消');
        _backendDownUntil = DateTime.now().add(const Duration(seconds: 30));
        return _original(hit);
      } on HttpRequestFailure catch (e) {
        if (!cancellation.isCancelled &&
            (e.retryable ||
                {
                  'connectionError',
                  'connectionTimeout',
                  'receiveTimeout',
                  'sendTimeout',
                }.contains(e.kind))) {
          _backendDownUntil = DateTime.now().add(const Duration(seconds: 30));
          return _original(hit);
        }
        rethrow;
      }
    }
    throw const AppException('请稍后重试');
  }

  DateTime? _backendDownUntil;
  ResourceSearchOpenResult _original(ResourceSearchHit hit) =>
      ResourceSearchOpenResult(
        hit: hit,
        mode: 'original',
        reason: 'backend_unavailable',
      );

  Future<ResourceSearchOpenResult> _openOnce(
    ResourceSearchHit hit,
    CancelToken cancellation, {
    required ResourceSearchFileSelection selection,
  }) async {
    require(!cancellation.isCancelled, '打开已取消');
    require(
      selection.fileId.isNotEmpty && selection.name.isNotEmpty,
      '请重新选择具体文件预览',
    );
    // A distinct route prevents older servers from ignoring the file selection
    // and performing a whole-share transfer before the client can reject it.
    final native = hit.openTicket.isEmpty || _expired(hit.openTicket);
    final url = '$endpoint/api/v1/search/${native ? 'client/' : ''}open/file';
    final body = jsonEncode({
      if (!native) 'ticket': hit.openTicket,
      if (native) ...{
        'url': hit.url,
        'title': hit.title,
        'password': hit.password,
      },
      'selection': selection.toJson(),
    });
    final token = CancelToken();
    final identity = await _identity();
    var timedOut = false, finished = false;
    unawaited(
      cancellation.whenCancel.then((_) {
        if (!finished) token.cancel();
      }),
    );
    final timer = Timer(const Duration(seconds: 20), () {
      timedOut = true;
      token.cancel();
    });
    try {
      final client = http;
      final HttpResult response;
      if (client is DioJsonHttp) {
        // A transfer is a mutation: send it once, with no automatic replay.
        final result = await client.dio.post<String>(
          url,
          data: body,
          cancelToken: token,
          options: Options(
            contentType: 'application/json; charset=utf-8',
            responseType: ResponseType.plain,
            receiveTimeout: const Duration(seconds: 20),
            sendTimeout: const Duration(seconds: 5),
            followRedirects: false,
            headers: {
              'Accept': 'application/json',
              'X-Resource-Client': identity,
              ...security.headers,
            },
          ),
        );
        response = HttpResult(result.statusCode ?? 0, result.data ?? '');
      } else {
        final scope = RequestScope();
        unawaited(token.whenCancel.then((_) => scope.cancel()));
        if (token.isCancelled) scope.cancel();
        response = await scope.run(
          () => RequestScope.cancellable(
            client.mutationRequest(
              'POST',
              url,
              body: body,
              headers: {'X-Resource-Client': identity, ...security.headers},
              contentType: 'application/json; charset=utf-8',
              followRedirects: false,
            ),
          ),
        );
      }
      require(!token.isCancelled, '打开已取消');
      if ({500, 502, 503, 504}.contains(response.status) ||
          native && {404, 405}.contains(response.status)) {
        throw const _BackendUnavailable();
      }
      require(response.body.length <= 128 * 1024, '转存服务响应过大');
      if (response.status == 403 &&
          _json(response.body)['code'] == 'HUMAN_VERIFICATION_REQUIRED') {
        throw const SearchVerificationRequired();
      }
      if ({404, 405}.contains(response.status)) {
        throw const AppException('搜索服务暂不支持单文件转存，请更新服务端后重试');
      }
      final value = _json(response.body);
      if (response.status == 403 &&
          value['code'] == 'HUMAN_VERIFICATION_REQUIRED') {
        throw const SearchVerificationRequired();
      }
      if (response.status == 429) throw const AppException('打开较频繁，请稍等片刻再试');
      require(
        response.status == 200 && value['success'] == true,
        value.str('message').ifEmpty('转存暂时未完成，请稍后重试'),
      );
      final result = ResourceSearchOpenResult.fromJson(hit, value.obj('data'));
      require(
        !result.transferred ||
            result.transferScope == 'file' &&
                result.sourceFileId == selection.fileId,
        '转存服务未确认单文件范围，请更新服务端后重试',
      );
      return result;
    } catch (e) {
      if (timedOut) {
        throw const _BackendUnavailable();
      }
      if (e is DioException && !CancelToken.isCancel(e)) {
        if ({
          DioExceptionType.connectionTimeout,
          DioExceptionType.sendTimeout,
          DioExceptionType.receiveTimeout,
          DioExceptionType.connectionError,
          DioExceptionType.unknown,
        }.contains(e.type)) {
          throw const _BackendUnavailable();
        }
      }
      rethrow;
    } finally {
      finished = true;
      timer.cancel();
    }
  }

  @override
  Stream<ResourceSearchBatch> search(
    String keyword,
    CancelToken cancellation,
  ) async* {
    final local = clientSearch;
    if (local != null) {
      await prepareSources(cancellation);
      require(!local.disabled, 'App 搜索暂未开放');
      if (local.available) {
        yield* local.search(keyword, cancellation, _serverSources);
        return;
      }
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await for (final batch in _searchOnce(keyword, cancellation)) {
          yield batch;
        }
        return;
      } on SearchVerificationRequired {
        if (attempt != 0) rethrow;
        await security.ensure(cancellation);
      }
    }
  }

  bool _expired(String ticket) {
    try {
      final payload = asJson(
        jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(ticket.split('.')[1])),
          ),
        ),
      );
      return payload.integer('exp') <=
          DateTime.now().millisecondsSinceEpoch ~/ 1000;
    } catch (_) {
      return false;
    }
  }

  Future<Json> _manifest(CancelToken cancellation) async {
    final scope = RequestScope();
    final cancel = cancellation.whenCancel.asStream().listen(
      (_) => scope.cancel(),
    );
    if (cancellation.isCancelled) scope.cancel();
    try {
      final response = await scope
          .run(
            () => RequestScope.cancellable(
              http.get('$endpoint/api/v1/search/client/config'),
            ),
          )
          .timeout(
            const Duration(seconds: 4),
            onTimeout: () {
              scope.cancel();
              throw const _BackendUnavailable();
            },
          );
      require(
        response.status == 200 && response.body.length < 16000000,
        '搜索配置暂时不可用',
      );
      return _json(response.body);
    } finally {
      scope.cancel();
      await cancel.cancel();
    }
  }

  Stream<ResourceSearchBatch> _serverSources(
    String keyword,
    List<String> sources,
    CancelToken token,
  ) async* {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        yield* _serverSourcesOnce(keyword, sources, token);
        return;
      } on SearchVerificationRequired {
        if (attempt != 0) rethrow;
        await security.ensure(token);
      }
    }
  }

  Stream<ResourceSearchBatch> _serverSourcesOnce(
    String keyword,
    List<String> sources,
    CancelToken token,
  ) async* {
    final url = query('$endpoint/api/v1/search/client/server', {
      'keyword': keyword,
      'sources': sources.join(','),
    });
    final client = http;
    if (client is! DioJsonHttp) return;
    final response = await client.dio.get<ResponseBody>(
      url,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(seconds: 35),
        headers: {'Accept': 'text/event-stream', ...security.headers},
      ),
    );
    if (response.statusCode != 200) {
      final bytes = <int>[];
      await for (final chunk in response.data!.stream) {
        bytes.addAll(chunk.take(65536 - bytes.length));
        if (bytes.length >= 65536) break;
      }
      _checkStatus(
        response.statusCode ?? 0,
        _json(utf8.decode(bytes, allowMalformed: true)),
      );
    }
    await for (final value in decodeSearchEvents(response.data!.stream)) {
      if (value['type'] == 'error') throw AppException(value.str('message'));
      final batch = ResourceSearchBatch.fromJson(value);
      yield batch;
      if (batch.complete) return;
    }
    throw const AppException('后台搜索连接中断');
  }

  Stream<ResourceSearchBatch> _searchOnce(
    String keyword,
    CancelToken cancellation,
  ) async* {
    final client = http;
    if (client is DioJsonHttp) {
      try {
        await for (final batch in _stream(client.dio, keyword, cancellation)) {
          yield batch;
        }
        return;
      } on _StreamUnavailable {
        // Older servers can still provide the ordinary JSON endpoint.
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow;
        throw const AppException('搜索连接中断，请检查网络后重试');
      }
    }
    final scope = RequestScope();
    unawaited(cancellation.whenCancel.then((_) => scope.cancel()));
    if (cancellation.isCancelled) scope.cancel();
    final response = await scope.run(
      () => RequestScope.cancellable(
        http.get(_url('search', keyword), security.headers),
      ),
    );
    if (cancellation.isCancelled) throw const AppException('搜索已停止');
    require(response.body.length <= 4 * 1024 * 1024, '搜索结果过大，请更换关键词');
    final value = _json(response.body);
    _checkStatus(response.status, value);
    yield ResourceSearchBatch.fromJson(value);
  }

  Stream<ResourceSearchBatch> _stream(
    Dio dio,
    String keyword,
    CancelToken token,
  ) async* {
    final response = await dio.get<ResponseBody>(
      _url('search/stream', keyword),
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(seconds: 40),
        headers: {'Accept': 'text/event-stream', ...security.headers},
      ),
    );
    final body = response.data;
    require(body != null, '搜索服务没有返回内容');
    if ({404, 405, 406}.contains(response.statusCode)) {
      await body!.stream.listen(null).cancel();
      throw const _StreamUnavailable();
    }
    if (response.statusCode != 200) {
      final bytes = <int>[];
      await for (final chunk in body!.stream) {
        bytes.addAll(chunk.take(65536 - bytes.length));
        if (bytes.length >= 65536) break;
      }
      _checkStatus(
        response.statusCode ?? 0,
        _json(utf8.decode(bytes, allowMalformed: true)),
      );
    }
    if (!(response.headers.value('content-type') ?? '').contains(
      'text/event-stream',
    )) {
      await body!.stream.listen(null).cancel();
      throw const _StreamUnavailable();
    }
    await for (final value in decodeSearchEvents(body!.stream)) {
      if (value['type'] == 'error') {
        throw AppException(value.str('message').ifEmpty('搜索暂时不可用'));
      }
      if (!{'initial', 'update', 'complete'}.contains(value['type'])) continue;
      final batch = ResourceSearchBatch.fromJson(value);
      yield batch;
      if (batch.complete) return;
    }
    throw const AppException('搜索连接已断开，已找到的结果已保留');
  }

  static Json _json(String body) {
    try {
      return asJson(jsonDecode(body));
    } on FormatException {
      throw const AppException('搜索服务返回异常，请稍后重试');
    }
  }

  static void _checkStatus(int status, Json value) {
    if (status == 403 && value['code'] == 'HUMAN_VERIFICATION_REQUIRED') {
      throw const SearchVerificationRequired();
    }
    if (status == 429) throw const AppException('搜索较频繁，请稍等片刻再试');
    if (status == 403) throw const AppException('搜索服务暂未开放，请稍后重试');
    require(status == 200, value.str('message').ifEmpty('搜索服务暂时不可用，请稍后重试'));
  }
}

class _StreamUnavailable implements Exception {
  const _StreamUnavailable();
}

class _BackendUnavailable implements Exception {
  const _BackendUnavailable();
}

/// Decode UTF-8 and SSE frames across arbitrary network chunk boundaries.
Stream<Json> decodeSearchEvents(Stream<List<int>> stream) async* {
  var frameSize = 0;
  final data = <String>[];
  final lines = stream
      .map<List<int>>((chunk) => chunk)
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  await for (final line in lines) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield asJson(jsonDecode(data.join('\n')));
        data.clear();
        frameSize = 0;
      }
    } else if (line.startsWith('data:')) {
      frameSize += line.length;
      require(frameSize <= 4 * 1024 * 1024, '单批搜索响应过大');
      data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
    }
  }
  if (data.isNotEmpty) yield asJson(jsonDecode(data.join('\n')));
}
