import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../http.dart';
import 'rule.dart';

/// Isolated, bounded HTTP transport. No shared Cookie jar or account headers.
class ParserRuleHttp extends JsonHttp {
  ParserRuleHttp({
    @visibleForTesting HttpClient Function()? clientFactory,
    @visibleForTesting this.connectTimeout = const Duration(seconds: 12),
    @visibleForTesting this.requestTimeout = const Duration(seconds: 65),
  }) : _clientFactory = clientFactory;

  final HttpClient Function()? _clientFactory;
  final Duration connectTimeout;
  final Duration requestTimeout;
  HttpClient? _client;

  static HttpClient _configureClient(HttpClient client) => client
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15);

  HttpClient _pooledClient() =>
      _client ??= _configureClient(_clientFactory?.call() ?? HttpClient());

  void close({bool force = false}) {
    _client?.close(force: force);
    _client = null;
  }

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    RequestScope.checkpoint();
    final ownsClient = _clientFactory == null && HttpOverrides.current != null;
    final client = ownsClient
        ? _configureClient(HttpClient())
        : _pooledClient();
    final elapsed = Stopwatch()..start();
    var phase = 'connect';
    int? status;
    HttpClientRequest? request;
    var aborted = false;
    void abortRequest([HttpClientRequest? target]) {
      aborted = true;
      (target ?? request)?.abort();
    }

    final token = RequestScope.current;
    final cancellation = token?.whenCancel.asStream().listen((_) {
      abortRequest();
    });
    try {
      final openFuture = client.openUrl(method, Uri.parse(url));
      unawaited(
        openFuture.then(
          (lateRequest) {
            if (aborted) lateRequest.abort();
          },
          onError: (Object _, StackTrace _) {},
        ),
      );
      request = await RequestScope.cancellable(openFuture).timeout(
        connectTimeout,
        onTimeout: () {
          abortRequest();
          throw TimeoutException('Parser rule connect timed out');
        },
      );
      if (aborted) {
        abortRequest(request);
        RequestScope.checkpoint();
      }
      phase = 'send';
      request.followRedirects = false;
      request.maxRedirects = 0;
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      if (contentType != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      final activeRequest = request;
      RequestScope.checkpoint();
      if (body != null) {
        activeRequest.add(utf8.encode(body is String ? body : jsonEncode(body)));
      }
      return await (() async {
        final response = await activeRequest.close();
        phase = 'receive';
        status = response.statusCode;
        final bytes = <int>[];
        await for (final chunk in response) {
          RequestScope.checkpoint();
          if (bytes.length + chunk.length > 1048576) {
            abortRequest(activeRequest);
            throw const ParserRuleError('RULE_RESPONSE', '解析服务响应过大');
          }
          bytes.addAll(chunk);
        }
        final resultHeaders = <String, List<String>>{};
        response.headers.forEach((key, value) => resultHeaders[key] = value);
        return HttpResult(
          response.statusCode,
          utf8.decode(bytes, allowMalformed: true),
          resultHeaders,
        );
      })().timeout(
        requestTimeout,
        onTimeout: () {
          abortRequest(activeRequest);
          throw TimeoutException('Parser rule request timed out');
        },
      );
    } on AppException {
      abortRequest();
      rethrow;
    } catch (error) {
      abortRequest();
      RequestScope.checkpoint();
      DiagnosticLog.event(
        'parser.upstream.network_failed',
        fields: {
          'host': Uri.tryParse(url)?.host,
          'method': method,
          'transport': 'dart',
          'phase': phase,
          'errorKind': _networkErrorKind(error),
          'httpStatus': ?status,
          if (error is SocketException && error.osError != null)
            'osCode': error.osError!.errorCode,
          if (error is TlsException && error.osError != null)
            'osCode': error.osError!.errorCode,
          'elapsedMs': elapsed.elapsedMilliseconds,
        },
      );
      throw const ParserRuleError('RULE_NETWORK', '解析服务连接失败，请检查网络后重试');
    } finally {
      await cancellation?.cancel();
      if (ownsClient) client.close(force: true);
    }
  }

  static String _networkErrorKind(Object error) {
    if (error is TimeoutException) return 'timeout';
    if (error is TlsException) return 'tls';
    if (error is SocketException) {
      // Classify locally; raw exception messages may contain full URLs or IPs.
      final message = error.message.toLowerCase();
      if (message.contains('host lookup') ||
          message.contains('name resolution') ||
          message.contains('nodename')) {
        return 'dns';
      }
      if (message.contains('timed out') || message.contains('timeout')) {
        return 'timeout';
      }
      if (message.contains('refused')) return 'connection_refused';
      if (message.contains('reset')) return 'connection_reset';
      return 'socket';
    }
    if (error is HttpException) return 'http';
    return 'other';
  }
}
