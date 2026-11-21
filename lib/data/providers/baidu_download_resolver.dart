import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../http.dart';
import '../http_retry.dart';
import 'baidu_link_service.dart';
import 'baidu_local_preview.dart';

/// Small ordinary files prefer local preview; other files try the relay first.
class BaiduDownloadResolver {
  BaiduDownloadResolver(
    this.http, {
    BaiduLinkLookup? relay,
    BaiduLinkLookup? preview,
  }) : relay =
           relay ??
           BaiduLinkService(
             http,
             endpoint: const String.fromEnvironment(
               'ASTERLINK_BAIDU_RELAY_API_URL',
             ),
           ).resolve,
       preview = preview ?? BaiduLocalPreview(http).resolve,
       _previewOnly = preview ?? BaiduLocalPreview(http).resolvePreview;

  final JsonHttp http;
  final BaiduLinkLookup relay, preview;
  final BaiduLinkLookup _previewOnly;
  // File sizes use the same binary units as the app's file lists.
  static const _previewLimit = 300 * 1024 * 1024;

  Future<BaiduResolvedLink> resolve({
    required String cookie,
    required String path,
    required String fileId,
    required String appId,
    required Json device,
    int fileSize = 0,
  }) async {
    RequestScope.checkpoint();
    if (fileSize > 0 && fileSize < _previewLimit) {
      try {
        return await ReadRetryScope.withoutRetries(() async {
          final result = await _previewOnly(
            cookie: cookie,
            path: path,
            fileId: fileId,
            appId: appId,
            device: device,
          );
          RequestScope.checkpoint();
          require(
            result.profile == 'baidu_preview' && result.url.isNotEmpty,
            '百度本地预览暂不可用',
          );
          DiagnosticLog.event(
            'baidu.download_route',
            fields: {'profile': result.profile, 'fileSize': fileSize},
          );
          return result;
        });
      } on AccountLoginRequired {
        RequestScope.checkpoint();
        rethrow;
      } catch (error) {
        RequestScope.checkpoint();
        DiagnosticLog.event(
          'baidu.preview_relay_fallback',
          fields: {
            'reason': error is HttpRequestFailure
                ? error.kind
                : error.runtimeType.toString(),
          },
        );
      }
    }
    try {
      // Do not spend the preparation retry budget on a failed first route.
      return await ReadRetryScope.withoutRetries(() async {
        final result = await relay(
          cookie: cookie,
          path: path,
          fileId: fileId,
          appId: appId,
          device: device,
        );
        RequestScope.checkpoint();
        require(result.profile == 'baidu_direct', '百度账号直链暂不可用');
        // Check the CDN so a rejected ticket falls back before enqueue.
        final probe = await http.peek(
          result.url,
          result.headers,
          maxBytes: 1,
          followRedirects: false,
        );
        RequestScope.checkpoint();
        require(
          probe.status == 206 &&
              RegExp(
                r'^bytes 0-0/[1-9]\d*$',
              ).hasMatch(probe.header('content-range')) &&
              probe.body.isNotEmpty,
          '百度账号直链暂不可用',
        );
        return result;
      });
    } catch (error) {
      RequestScope.checkpoint();
      DiagnosticLog.event(
        'baidu.local_preview_fallback',
        fields: {
          'reason': error is HttpRequestFailure
              ? error.kind
              : error.runtimeType.toString(),
        },
      );
    }
    final result = await preview(
      cookie: cookie,
      path: path,
      fileId: fileId,
      appId: appId,
      device: device,
    );
    RequestScope.checkpoint();
    return result;
  }
}
