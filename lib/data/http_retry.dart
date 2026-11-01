import 'dart:async';
import 'dart:io';
import '../domain/download_retries.dart';
import 'http.dart';

class ReadRetryAttempt {
  const ReadRetryAttempt(this.number, this.delay, this.failure);
  final int number;
  final Duration delay;
  final HttpRequestFailure failure;
}

/// One bounded budget for all read requests in a single preparation operation.
class ReadRetryScope {
  ReadRetryScope({
    required int retries,
    required this.checkpoint,
    this.onRetry,
    this.wait = RequestScope.wait,
  }) : retries = retries.clamp(0, maxDownloadRetries);

  static final _key = Object();
  static ReadRetryScope? get current => Zone.current[_key] as ReadRetryScope?;
  static const transientStatuses = {408, 425, 429, 500, 502, 503, 504};
  final int retries;
  final void Function() checkpoint;
  final Future<void> Function(ReadRetryAttempt)? onRetry;
  final Future<void> Function(Duration) wait;
  int _attempts = 0;

  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: this});

  /// A route with its own fallback should try once before changing routes.
  static Future<T> withoutRetries<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: null});

  Future<HttpResult> execute(Future<HttpResult> Function() request) async {
    while (true) {
      checkpoint();
      HttpRequestFailure failure;
      try {
        final response = await request();
        checkpoint();
        if (!transientStatuses.contains(response.status)) return response;
        failure = HttpRequestFailure(
          response.status == 429
              ? '服务器请求过于频繁，请稍后重试'
              : '服务暂时不可用（HTTP ${response.status}），请稍后重试',
          kind: 'http',
          status: response.status,
          retryAfter: response.header('retry-after'),
          retryable: true,
        );
      } on HttpRequestFailure catch (error) {
        failure = error;
      } on SocketException {
        failure = const HttpRequestFailure(
          '网络连接失败，请检查网络后重试',
          kind: 'connectionError',
          retryable: true,
        );
      } on TimeoutException {
        failure = const HttpRequestFailure(
          '连接超时，请稍后重试',
          kind: 'receiveTimeout',
          retryable: true,
        );
      }
      checkpoint();
      if (!failure.retryable || _attempts >= retries) throw failure;
      final normal = Duration(seconds: const [2, 5, 10][_attempts.clamp(0, 2)]);
      final server = _retryAfter(failure.retryAfter);
      final delay = server != null && server > normal ? server : normal;
      final attempt = ReadRetryAttempt(++_attempts, delay, failure);
      await onRetry?.call(attempt);
      checkpoint();
      await wait(delay);
      checkpoint();
    }
  }

  Duration? _retryAfter(String value) {
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    try {
      final remaining = HttpDate.parse(
        value,
      ).difference(DateTime.now().toUtc());
      return remaining.isNegative ? Duration.zero : remaining;
    } catch (_) {
      return null;
    }
  }
}

class RetryingJsonHttp extends JsonHttp {
  RetryingJsonHttp(this.delegate);
  final JsonHttp delegate;

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) {
    Future<HttpResult> send() => delegate.request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    );
    final scope = ReadRetryScope.current;
    return scope != null && JsonHttp.isReadRequest(method, url)
        ? scope.execute(send)
        : send();
  }

  @override
  Future<HttpResult> peek(
    String url,
    Map<String, String> headers, {
    int maxBytes = 8192,
    bool followRedirects = true,
  }) {
    Future<HttpResult> send() => delegate.peek(
      url,
      headers,
      maxBytes: maxBytes,
      followRedirects: followRedirects,
    );
    return ReadRetryScope.current?.execute(send) ?? send();
  }
}
