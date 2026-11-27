import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../core/html_entities.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/system_proxy_http_adapter.dart';
import '../diagnostics/app_log.dart';
import '../domain/download_network_policy.dart';
import '../download/transfer_http.dart';
import '../platform/windows_system_proxy.dart';
import 'subtitle_files.dart';

/// Only a filename or the user's search words leave the device.
String onlineSubtitleQuery(String name) {
  final value = name.trim(), uri = Uri.tryParse(name.trim());
  if (uri != null && {'http', 'https'}.contains(uri.scheme)) {
    return uri.pathSegments.lastOrNull ?? '';
  }
  return value.replaceAll('\\', '/').split('/').last.trim();
}

String _displayText(String value) => unescapeDisplayName(
  value.replaceAllMapped(
    RegExp(r'\\u([0-9a-fA-F]{4})'),
    (match) => String.fromCharCode(int.parse(match[1]!, radix: 16)),
  ),
).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();

/// Keep only error categories and numeric codes. Search words, subtitle URLs
/// and proxy addresses are not needed to diagnose a failed connection.
Map<String, Object?> onlineSubtitleFailureFields(Object error) {
  final fields = <String, Object?>{};
  Object? cause = error;
  if (cause is DownloadHttpException) {
    fields['httpStatus'] = cause.status;
  }
  if (cause is DownloadNetworkException) {
    fields['kind'] = cause.kind;
    fields['retryable'] = cause.retryable;
    cause = cause.cause ?? cause;
  }
  if (cause is DioException) {
    fields['kind'] = cause.type.name;
    cause = cause.error ?? cause;
  }
  if (cause is WindowsProxyException) {
    fields['proxyReason'] = cause.reason;
    fields['systemCode'] = cause.systemCode;
    cause = cause.cause ?? cause;
  }
  fields['causeType'] = cause.runtimeType.toString();
  if (cause is SocketException) {
    fields['errno'] = cause.osError?.errorCode;
    fields['dns'] = cause.message.toLowerCase().contains('host lookup');
  }
  if (cause is TlsException) {
    fields['tls'] = true;
    fields['certificate'] = '${cause.message} ${cause.osError?.message ?? ''}'
        .toUpperCase()
        .contains('CERTIFICATE_VERIFY_FAILED');
  }
  if (cause is TimeoutException ||
      {
        'connectionTimeout',
        'receiveTimeout',
        'sendTimeout',
      }.contains(fields['kind'])) {
    fields['timedOut'] = true;
  }
  return fields;
}

String onlineSubtitleErrorMessage(Object error, {required bool searching}) {
  final operation = searching ? '在线字幕搜索' : '字幕下载';
  final fields = onlineSubtitleFailureFields(error);
  if (fields['proxyReason'] case final String reason) {
    return '$operation失败：${WindowsProxyException(reason).message}';
  }
  if (fields['dns'] == true) {
    return '$operation无法解析服务地址，请检查网络或 DNS 后重试';
  }
  if (fields['timedOut'] == true) return '$operation连接超时，请稍后重试';
  if (fields['kind'] == 'badCertificate' || fields['certificate'] == true) {
    return '$operation证书校验失败，请检查系统时间和网络设置';
  }
  if (fields['tls'] == true) return '$operation安全连接失败，请检查网络后重试';
  if (error is DownloadNetworkException ||
      error is DioException ||
      error is SocketException ||
      error is HttpException) {
    return '$operation连接失败，请检查网络后重试';
  }
  if (error is DownloadHttpException) {
    if (error.status == 429) return error.message;
    if (!searching && {401, 403, 404, 410}.contains(error.status)) {
      return '字幕下载地址已失效，请重新搜索';
    }
    return '$operation服务暂不可用（HTTP ${error.status}），请稍后重试';
  }
  return error is AppException
      ? error.message
      : searching
      ? '在线字幕搜索失败，请检查网络后重试'
      : '字幕加载失败，请重新选择或重试';
}

bool _retryableSubtitleRequest(Object error) {
  final fields = onlineSubtitleFailureFields(error);
  final proxy = fields['proxyReason'];
  if (proxy != null && proxy != 'connection') return false;
  if (fields['certificate'] == true) return false;
  return retryableDownloadError(error);
}

class OnlineSubtitle {
  const OnlineSubtitle({
    required this.url,
    required this.name,
    required this.title,
    required this.format,
    this.languages = const [],
    this.duration,
  });
  final String url, name, title, format;
  final List<String> languages;
  final Duration? duration;

  static OnlineSubtitle? fromJson(Json json) {
    final uri = Uri.tryParse(json.str('url'));
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final original = onlineSubtitleQuery(
      _displayText(json.str('name')).ifEmpty(p.basename(uri.path)),
    );
    final format = json
        .str('ext', p.extension(original))
        .toLowerCase()
        .replaceFirst(RegExp(r'^\.'), '')
        .trim();
    if (!SubtitleFiles.extensions.contains(format)) return null;
    final name = '${p.withoutExtension(original).ifEmpty('在线字幕')}.$format';
    final languages = json['languages'];
    final milliseconds = json.integer('duration');
    return OnlineSubtitle(
      url: uri.removeFragment().toString(),
      name: name,
      title: _displayText(json.str('simple_name')).ifEmpty(name),
      format: format,
      languages: List.unmodifiable(
        languages is List
            ? languages
                  .whereType<String>()
                  .map((s) => _displayText(s).replaceAll('&', ' / '))
                  .where((s) => s.isNotEmpty)
                  .toSet()
            : <String>[],
      ),
      duration: milliseconds > 0 ? Duration(milliseconds: milliseconds) : null,
    );
  }
}

abstract interface class OnlineSubtitleService {
  Future<List<OnlineSubtitle>> search(String name, RequestScope scope);
  Future<File> download(
    OnlineSubtitle subtitle,
    Directory directory,
    RequestScope scope,
  );
  void close();
}

/// A dedicated transport never inherits a video source's cookies or headers.
class XunleiOnlineSubtitleService implements OnlineSubtitleService {
  XunleiOnlineSubtitleService({
    TransferHttp? http,
    WindowsSystemProxy? systemProxy,
    this.wait = RequestScope.wait,
  }) : _http = http ?? _createHttp(systemProxy),
       _ownsHttp = http == null;
  static const endpoint = 'https://api-shoulei-ssl.xunlei.com/oracle/subtitle';
  static const maximumSearchBytes = 2 * 1024 * 1024;
  static const maximumRetries = 1;
  final TransferHttp _http;
  final bool _ownsHttp;
  final Future<void> Function(Duration) wait;
  final _scopes = <RequestScope>{};
  bool _closed = false;

  static bool _systemProxyRequest(Uri uri) {
    if (!{'http', 'https'}.contains(uri.scheme)) return false;
    final address = InternetAddress.tryParse(uri.host);
    return address == null || DownloadNetworkPolicy.publicAddress(address);
  }

  static TransferHttp _createHttp(WindowsSystemProxy? systemProxy) {
    final http = TransferHttp();
    if (Platform.isWindows || systemProxy != null) {
      final proxy = systemProxy ?? WindowsSystemProxy();
      http.dio.httpClientAdapter = SystemProxyHttpClientAdapter(
        resolve: (uri) async {
          final route = await proxy.resolve(uri);
          if (route.source == 'direct') {
            final environment = HttpClient.findProxyFromEnvironment(uri);
            if (environment != 'DIRECT') {
              return WindowsProxyRoute(environment, 'environment');
            }
          }
          return route;
        },
        shouldProxy: _systemProxyRequest,
        diagnosticPlatform: '在线字幕',
        createHttpClient: () => HttpClient()
          ..userAgent = null
          ..idleTimeout = const Duration(seconds: 3)
          ..findProxy = (uri) => _systemProxyRequest(uri)
              ? HttpClient.findProxyFromEnvironment(uri)
              : 'DIRECT',
      );
    }
    return http;
  }

  Future<T> _read<T>(String stage, Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      RequestScope.checkpoint();
      try {
        return await action();
      } catch (error) {
        RequestScope.checkpoint();
        if (attempt >= maximumRetries || !_retryableSubtitleRequest(error)) {
          rethrow;
        }
        final delay = downloadRetryDelay(attempt, error);
        // Respect a long Retry-After by returning the error for a later manual
        // retry, rather than retrying too early or blocking this panel.
        if (delay > const Duration(seconds: 5)) rethrow;
        DiagnosticLog.event(
          'player.online_subtitle_retry',
          fields: {
            'stage': stage,
            'attempt': attempt + 1,
            'delayMs': delay.inMilliseconds,
            ...onlineSubtitleFailureFields(error),
          },
        );
        await wait(delay);
        RequestScope.checkpoint();
      }
    }
  }

  Future<T> _request<T>(RequestScope scope, Future<T> Function() action) async {
    require(!_closed, '在线字幕已关闭');
    _scopes.add(scope);
    try {
      return await scope.run(() async {
        RequestScope.checkpoint();
        return await action();
      });
    } finally {
      _scopes.remove(scope);
    }
  }

  @override
  Future<List<OnlineSubtitle>> search(String name, RequestScope scope) =>
      _request(scope, () async {
        final keyword = onlineSubtitleQuery(name);
        require(keyword.isNotEmpty, '请输入视频名称');
        require(keyword.length <= 512, '视频名称不能超过 512 个字符');
        final url = Uri.parse(
          endpoint,
        ).replace(queryParameters: {'name': keyword});
        final bytes = await _read(
          'search',
          () => _http.limited(url.toString(), const {
            'Accept': 'application/json',
          }, maximumSearchBytes),
        );
        RequestScope.checkpoint();
        Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          throw const AppException('在线字幕服务响应异常，请重试');
        }
        require(decoded is Map, '在线字幕服务响应异常，请重试');
        final json = asJson(decoded);
        require(json.integer('code', -1) == 0, '在线字幕服务暂不可用，请稍后重试');
        require(json['data'] == null || json['data'] is List, '在线字幕服务响应异常，请重试');
        final results = <OnlineSubtitle>[], seen = <String>{};
        for (final item in objects(json['data'])) {
          final subtitle = OnlineSubtitle.fromJson(item);
          if (subtitle != null && seen.add(subtitle.url)) results.add(subtitle);
        }
        return List.unmodifiable(results);
      });

  @override
  Future<File> download(
    OnlineSubtitle subtitle,
    Directory directory,
    RequestScope scope,
  ) => _request(
    scope,
    () => _read('download', () async {
      require(
        OnlineSubtitle.fromJson({
              'url': subtitle.url,
              'name': subtitle.name,
              'ext': subtitle.format,
            }) !=
            null,
        '字幕下载地址或格式无效，请重新搜索',
      );
      final cancel = CancelToken();
      final relay = scope.token.whenCancel.asStream().listen((_) {
        if (!cancel.isCancelled) cancel.cancel();
      });
      File? pending;
      try {
        final response = await _http.stream(
          subtitle.url,
          _http.headers(const {}),
          cancel: cancel,
        );
        if (response.statusCode != 200) {
          throw DownloadHttpException.response(response);
        }
        require(response.data != null, '字幕下载失败，请重试');
        final length = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        require(
          length == null || length <= SubtitleFiles.maximumBytes,
          '字幕文件不能超过 8 MB',
        );
        final type =
            response.headers.value('content-type')?.toLowerCase() ?? '';
        require(
          !type.contains('text/html') && !type.contains('application/json'),
          '字幕下载地址已失效，请重新搜索',
        );
        pending = await SubtitleFiles(
          directory,
        ).stage(subtitle.name, response.data!.stream);
        RequestScope.checkpoint();
        final file = pending;
        pending = null;
        return file;
      } finally {
        cancel.cancel();
        await relay.cancel();
        if (pending != null && await pending.exists()) await pending.delete();
      }
    }),
  );

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final scope in _scopes.toList()) {
      scope.cancel();
    }
    if (_ownsHttp) _http.dio.close(force: true);
  }
}
