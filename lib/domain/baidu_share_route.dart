import '../core/json.dart';
import 'models.dart';

enum BaiduShareRoute {
  account('account', '账号下载'),
  publicParser('mf_dg22', '公益解析');

  const BaiduShareRoute(this.key, this.label);
  final String key, label;
  static const metadataKey = 'baiduShareRoute';
  static const publicDownloadProfile = 'baidu_public';

  static BaiduShareRoute fromSession(BrowseSession session) =>
      session.platform == CloudPlatform.baidu &&
          session.mode == BrowseMode.share &&
          session.meta(metadataKey) == publicParser.key
      ? publicParser
      : account;

  static bool usesPublicParser(BrowseSession session) =>
      fromSession(session) == publicParser;

  static bool usesPublicDownload(DownloadSpec spec) {
    if (spec.profile == publicDownloadProfile) return true;
    if (spec.platform != CloudPlatform.baidu) return false;
    final session = asJson(spec.source?['session']);
    return session.str('mode').toLowerCase() == 'share' &&
        session.obj('metadata').str(metadataKey) == publicParser.key;
  }

  static String? downloadProfile(DownloadSpec spec) =>
      usesPublicDownload(spec) ? publicDownloadProfile : spec.profile;

  static bool usesAccountDownload(DownloadSpec spec) =>
      !usesPublicDownload(spec) &&
      (spec.platform == CloudPlatform.baidu ||
          {'baidu', 'baidu_preview', 'baidu_direct'}.contains(spec.profile));
}
