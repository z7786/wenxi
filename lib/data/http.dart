import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../core/json.dart';
import '../platform/windows_system_proxy.dart';
import 'system_proxy_http_adapter.dart';

class RequestScope {
  final token = CancelToken();
  static final _zoneKey = Object();
  static final _guardKey = Object();
  static CancelToken? get current =>
      (Zone.current[_zoneKey] as RequestScope?)?.token;
  static void checkpoint() {
    if (current?.isCancelled == true) throw const AppException('请求已取消');
    (Zone.current[_guardKey] as void Function()?)?.call();
  }

  static Future<T> guarded<T>(
    Future<T> Function() action,
    void Function() guard,
  ) {
    final parent = Zone.current[_guardKey] as void Function()?;
    return runZoned(
      action,
      zoneValues: {
        _guardKey: () {
          parent?.call();
          guard();
        },
      },
    );
  }

  Future<T> run<T>(Future<T> Function() action, {bool inheritGuard = true}) =>
      runZoned(
        action,
        zoneValues: {
          _zoneKey: this,
          // Shared, account-independent reads can own their cancellation scope.
          if (!inheritGuard) _guardKey: null,
        },
      );
  void cancel() => token.cancel();

  static Future<T> cancellable<T>(Future<T> operation) async {
    final token = current;
    final result = await Future.any<T>([
      operation,
      if (token != null)
        token.whenCancel.then<T>((_) => throw const AppException('请求已取消')),
    ]);
    checkpoint();
    return result;
  }

  static Future<void> wait(Duration duration) async {
    checkpoint();
    final elapsed = Completer<void>();
    final timer = Timer(duration, elapsed.complete);
    try {
      final token = current;
      await Future.any<void>([
        elapsed.future,
        if (token != null) token.whenCancel.then<void>((_) {}),
      ]);
      checkpoint();
    } finally {
      timer.cancel();
    }
  }
}

// dart:io emits these for a truncated response/header. Other HttpExceptions
// (invalid protocol, headers or redirects) are not transient network failures.
bool isInterruptedHttpConnection(Object? error) =>
    error is HttpException &&
    const {
      'Connection closed while receiving data',
      'Connection closed before full header was received',
    }.contains(error.message);

class HttpRequestFailure extends AppException {
  const HttpRequestFailure(
    super.message, {
    required this.kind,
    this.retryable = false,
    this.requestNotSent = false,
    this.status,
    this.retryAfter = '',
  });

  final String kind, retryAfter;
  final bool retryable, requestNotSent;
  final int? status;

  factory HttpRequestFailure.httpConnection(HttpException error) =>
      HttpRequestFailure(
        '网络连接失败，请检查网络后重试',
        kind: 'httpConnection',
        retryable: isInterruptedHttpConnection(error),
      );

  factory HttpRequestFailure.network(DioException error) => HttpRequestFailure(
    error.error is WindowsProxyException
        ? (error.error as WindowsProxyException).message
        : switch (error.type) {
            DioExceptionType.connectionTimeout ||
            DioExceptionType.receiveTimeout ||
            DioExceptionType.sendTimeout => '连接超时，请稍后重试',
            DioExceptionType.badCertificate => '服务器证书校验失败',
            DioExceptionType.cancel => '请求已取消',
            _ => '网络连接失败，请检查网络后重试',
          },
    kind: error.type.name,
    requestNotSent:
        error.error is HandshakeException ||
        error.type == DioExceptionType.connectionTimeout,
    retryable: switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.unknown =>
        error.error is SocketException ||
            isInterruptedHttpConnection(error.error) ||
            error.error is HandshakeException &&
                (error.error as HandshakeException).message ==
                    'Connection terminated during handshake',
      _ => false,
    },
  );
}

class HttpResult {
  const HttpResult(this.status, this.body, [this.headers = const {}]);
  final int status;
  final String body;
  final Map<String, List<String>> headers;
  bool get successful => status >= 200 && status < 300;
  Json get json {
    try {
      final value = jsonDecode(body);
      require(value is Map, '服务响应格式错误');
      return asJson(value);
    } on FormatException {
      throw AppException('服务响应不是有效 JSON（HTTP $status）');
    }
  }

  String header(String key) => headers[key.toLowerCase()]?.firstOrNull ?? '';
}

/// Reopened for each explicitly retried chunk; never buffers the whole file.
class HttpUpload {
  const HttpUpload({
    required this.open,
    required this.length,
    this.fields,
    this.fileName = 'upload.bin',
    this.fieldName = 'file',
    this.onProgress,
    this.binaryResponse = false,
  });
  final Stream<List<int>> Function() open;
  final int length;
  final Map<String, String>? fields;
  final String fileName, fieldName;
  final void Function(int sent, int total)? onProgress;
  final bool binaryResponse;

  Object data() => fields == null
      ? open()
      : FormData.fromMap({
          ...fields!,
          fieldName: MultipartFile.fromStream(open, length, filename: fileName),
        });
}

abstract class JsonHttp {
  static final _readKey = Object();
  static final _mutationKey = Object();

  static bool isReadRequest(String method, String url) {
    final verb = method.toUpperCase();
    if (Zone.current[_mutationKey] == (verb, url)) return false;
    return verb == 'GET' ||
        verb == 'HEAD' ||
        Zone.current[_readKey] == (verb, url);
  }

  // Only the exact request is marked: a nested token refresh is not replayed.
  Future<HttpResult> mutationRequest(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) => runZoned(
    () => request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    ),
    zoneValues: {_mutationKey: (method.toUpperCase(), url)},
  );

  Future<HttpResult> readRequest(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) => runZoned(
    () => request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    ),
    zoneValues: {_readKey: (method.toUpperCase(), url)},
  );

  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  });
  Future<HttpResult> get(
    String url, [
    Map<String, String> headers = const {},
  ]) => request('GET', url, headers: headers);
  Future<HttpResult> postJson(
    String url,
    Object? body, [
    Map<String, String> headers = const {},
  ]) => request(
    'POST',
    url,
    body: body is String ? body : jsonEncode(body),
    headers: headers,
    contentType: 'application/json; charset=utf-8',
  );
  Future<HttpResult> postForm(
    String url,
    String body, [
    Map<String, String> headers = const {},
  ]) => request(
    'POST',
    url,
    body: body,
    headers: headers,
    contentType: 'application/x-www-form-urlencoded; charset=utf-8',
  );
  Future<HttpResult> postJsonRead(
    String url,
    Object? body, [
    Map<String, String> headers = const {},
  ]) => readRequest(
    'POST',
    url,
    body: body is String ? body : jsonEncode(body),
    headers: headers,
    contentType: 'application/json; charset=utf-8',
  );
  Future<HttpResult> postFormRead(
    String url,
    String body, [
    Map<String, String> headers = const {},
  ]) => readRequest(
    'POST',
    url,
    body: body,
    headers: headers,
    contentType: 'application/x-www-form-urlencoded; charset=utf-8',
  );
  Future<HttpResult> peek(
    String url,
    Map<String, String> headers, {
    int maxBytes = 8192,
    bool followRedirects = true,
  }) => request(
    'GET',
    url,
    headers: {...headers, 'Range': 'bytes=0-${maxBytes - 1}'},
    followRedirects: followRedirects,
  );
}

class DioJsonHttp extends JsonHttp {
  DioJsonHttp({Dio? client})
    : dio =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 45),
              validateStatus: (_) => true,
            ),
          ) {
    if (client == null && Platform.isWindows) {
      dio.httpClientAdapter = SystemProxyHttpClientAdapter(
        resolve: WindowsSystemProxy().resolve,
      );
    }
  }
  final Dio dio;
  @override
  Future<HttpResult> peek(
    String url,
    Map<String, String> headers, {
    int maxBytes = 8192,
    bool followRedirects = true,
  }) async {
    RequestScope.checkpoint();
    require(maxBytes > 0 && maxBytes <= 2 * 1024 * 1024, '检查读取大小无效');
    final cancel = CancelToken();
    final parent = RequestScope.current;
    var finished = false;
    unawaited(
      parent?.whenCancel.then((_) {
        if (!finished) cancel.cancel();
      }),
    );
    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          headers: {...headers, 'Range': 'bytes=0-${maxBytes - 1}'},
          followRedirects: followRedirects,
          maxRedirects: 5,
        ),
      );
      final bytes = <int>[];
      await for (final chunk in response.data!.stream) {
        RequestScope.checkpoint();
        bytes.addAll(chunk.take(maxBytes - bytes.length));
        if (bytes.length >= maxBytes) break;
      }
      RequestScope.checkpoint();
      return HttpResult(
        response.statusCode ?? 0,
        utf8.decode(bytes, allowMalformed: true),
        response.headers.map,
      );
    } on DioException catch (error) {
      RequestScope.checkpoint();
      throw HttpRequestFailure.network(error);
    } on HttpException catch (error) {
      RequestScope.checkpoint();
      throw HttpRequestFailure.httpConnection(error);
    } finally {
      finished = true;
      cancel.cancel();
    }
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
    final uri = Uri.tryParse(url);
    require(
      uri != null &&
          ['https', 'http'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      '请求地址无效',
    );
    try {
      final upload = body is HttpUpload ? body : null;
      RequestScope.checkpoint();
      final response = await dio.request<dynamic>(
        url,
        data: upload?.data() ?? body,
        cancelToken: RequestScope.current,
        onSendProgress: upload?.onProgress,
        options: Options(
          method: method,
          headers: {
            if (upload != null && upload.fields == null)
              'Content-Length': '${upload.length}',
            for (final e in headers.entries)
              if (e.value.isNotEmpty) e.key: e.value,
          },
          contentType: upload?.fields != null
              ? 'multipart/form-data'
              : contentType,
          responseType: upload?.binaryResponse == true
              ? ResponseType.bytes
              : ResponseType.plain,
          sendTimeout: upload == null ? null : const Duration(minutes: 30),
          followRedirects: followRedirects,
          maxRedirects: 5,
        ),
      );
      RequestScope.checkpoint();
      return HttpResult(
        response.statusCode ?? 0,
        response.data is List<int>
            ? String.fromCharCodes(response.data! as List<int>)
            : response.data?.toString() ?? '',
        response.headers.map,
      );
    } on DioException catch (error) {
      // DioException.toString includes URLs, headers and possibly signed credentials.
      throw HttpRequestFailure.network(error);
    }
  }
}
