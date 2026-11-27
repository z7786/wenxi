import '../../core/json.dart';

/// A download link resolved on the device through Baidu's own APIs.
class BaiduResolvedLink {
  const BaiduResolvedLink({required this.url, this.preview = false});

  final String url;
  final bool preview;
  String get profile => preview ? 'baidu_preview' : 'baidu';
}

typedef BaiduLinkLookup =
    Future<BaiduResolvedLink> Function({
      required String cookie,
      required String path,
      required String fileId,
      required String appId,
      required Json device,
    });
