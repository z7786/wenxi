import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../http.dart';
import 'baidu_resolved_link.dart';
import 'baidu_local_preview.dart';

/// Account downloads always resolve on the device, regardless of file size.
class BaiduDownloadResolver {
  BaiduDownloadResolver(JsonHttp http, {BaiduLinkLookup? local})
    : _local = local ?? BaiduLocalPreview(http).resolve;

  final BaiduLinkLookup _local;

  Future<BaiduResolvedLink> resolve({
    required String cookie,
    required String path,
    required String fileId,
    required String appId,
    required Json device,
    int fileSize = 0,
  }) async {
    RequestScope.checkpoint();
    try {
      final result = await _local(
        cookie: cookie,
        path: path,
        fileId: fileId,
        appId: appId,
        device: device,
      );
      RequestScope.checkpoint();
      DiagnosticLog.event(
        'baidu.download_route',
        fields: {
          'route': 'local',
          'profile': result.profile,
          'fileSize': fileSize,
        },
      );
      return result;
    } catch (_) {
      RequestScope.checkpoint();
      rethrow;
    }
  }
}
