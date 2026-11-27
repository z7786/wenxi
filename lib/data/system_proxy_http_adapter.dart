import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import '../diagnostics/app_log.dart';
import '../platform/windows_system_proxy.dart';

class SystemProxyHttpClientAdapter implements HttpClientAdapter {
  SystemProxyHttpClientAdapter({
    required this.resolve,
    this.shouldProxy = pikpakRequest,
    this.diagnosticPlatform = 'PikPak',
    this.createHttpClient,
  }) : _direct = IOHttpClientAdapter(createHttpClient: createHttpClient);
  final Future<WindowsProxyRoute> Function(Uri) resolve;
  final bool Function(Uri) shouldProxy;
  final String diagnosticPlatform;
  final HttpClient Function()? createHttpClient;
  final IOHttpClientAdapter _direct;
  final _routes = <String, IOHttpClientAdapter>{};
  final _lastRoute = <String, (String, String)>{};
  bool _closed = false;

  static bool pikpakRequest(Uri uri) =>
      uri.scheme == 'https' &&
      {'user.mypikpak.com', 'api-drive.mypikpak.com'}.contains(uri.host);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('HTTP client is closed');
    if (!shouldProxy(options.uri)) {
      return _direct.fetch(options, requestStream, cancelFuture);
    }
    final timer = Stopwatch()..start();
    var cancelled = options.cancelToken?.isCancelled == true;
    if (cancelled) {
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: null,
      );
    }
    final cancelledFuture = cancelFuture?.then<WindowsProxyRoute>((_) {
      cancelled = true;
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: null,
      );
    });
    final timeout = options.connectTimeout;
    WindowsProxyRoute route;
    try {
      var resolving = Future.any([
        Future.sync(() => resolve(options.uri)),
        ?cancelledFuture,
      ]);
      if (timeout != null && timeout > Duration.zero) {
        resolving = resolving.timeout(
          timeout,
          onTimeout: () {
            throw DioException.connectionTimeout(
              requestOptions: options,
              timeout: timeout,
            );
          },
        );
      }
      route = await resolving;
    } on WindowsProxyException catch (error) {
      DiagnosticLog.event(
        'network.windows_proxy_failed',
        fields: {
          'platform': diagnosticPlatform,
          'reason': error.reason,
          if (error.systemCode != null) 'systemCode': error.systemCode,
        },
      );
      throw DioException.connectionError(
        requestOptions: options,
        reason: error.message,
        error: error,
      );
    }
    if (_closed || cancelled || options.cancelToken?.isCancelled == true) {
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: null,
      );
    }
    var routed = options;
    if (timeout != null && timeout > Duration.zero) {
      final remaining = timeout - timer.elapsed;
      if (remaining <= Duration.zero) {
        throw DioException.connectionTimeout(
          requestOptions: options,
          timeout: timeout,
        );
      }
      routed = options.copyWith(connectTimeout: remaining);
    }
    final identity = (route.value, route.source);
    if (_lastRoute[options.uri.host] != identity) {
      _lastRoute[options.uri.host] = identity;
      DiagnosticLog.event(
        'network.windows_proxy',
        fields: {
          'platform': diagnosticPlatform,
          'source': route.source,
          'usesProxy': route.usesProxy,
        },
      );
    }
    var adapter = _routes.remove(route.value);
    if (adapter == null) {
      while (_routes.length >= 8) {
        _routes.remove(_routes.keys.first)!.close();
      }
      adapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client =
              createHttpClient?.call() ??
              (HttpClient()..idleTimeout = const Duration(seconds: 3));
          return client..findProxy = (_) => route.value;
        },
      );
    }
    // Each route has its own connection pool. A connection opened before the
    // proxy was enabled must not turn a proxied request into a direct request.
    _routes[route.value] = adapter;
    try {
      return await adapter.fetch(routed, requestStream, cancelFuture);
    } on DioException catch (error) {
      if (route.usesProxy && error.type == DioExceptionType.connectionError) {
        throw error.copyWith(
          error: WindowsProxyException.connection(error.error),
        );
      }
      rethrow;
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _direct.close(force: force);
    for (final adapter in _routes.values) {
      adapter.close(force: force);
    }
    _routes.clear();
    _lastRoute.clear();
  }
}
