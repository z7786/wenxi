import '../../core/json.dart';
import '../../domain/cloud_file_time.dart';
import '../../domain/models.dart';

String personalCloudDate(String value) {
  final raw = value.trim();
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(raw)) return value;
  final date = cloudFileDate(raw);
  if (date == null) return value;
  if (raw.length == 8) return formatCloudFileTime(raw);
  return date
      .toIso8601String()
      .replaceFirst('T', ' ')
      .replaceFirst(RegExp(r'\.000$'), '');
}

abstract class PersonalCloudConnector extends CloudConnector {
  void personal(BrowseSession session) => require(
    session.platform == platform && session.mode == BrowseMode.personal,
    '请先打开${platform.shortName}个人网盘',
  );

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async => throw AppException(platform.shareUnavailableMessage);

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async => throw AppException('${platform.label}暂不支持创建分享');

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async => throw AppException('${platform.label}暂不支持转存分享');
}
