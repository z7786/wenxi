import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/quark_share_transfer.dart';
import '../../platform/quark_transfer_device.dart';
import '../http.dart';
import '../state_store.dart';
import '../../domain/models.dart';
import 'cookie_cloud.dart';
import 'quark_playback.dart';
import 'quark_mobile_transfer.dart';

class QuarkConnector extends CookieCloudConnector {
  QuarkConnector(
    JsonHttp http, {
    CredentialStore? store,
    Future<void> Function(DownloadCleanup)? stageCleanup,
    Duration taskDelay = const Duration(milliseconds: 750),
    int Function()? now,
    bool Function(bool authenticated)? directShareDownloadEnabled,
    QuarkTransferDevice? transferDevice,
  }) : super(
         CloudPlatform.quark,
         http,
         store: store,
         stageCleanup: stageCleanup,
         taskDelay: taskDelay,
         now: now,
         webUserAgent: webUa,
         apiUserAgent: cloudUa,
         directShareDownloadEnabled: directShareDownloadEnabled,
       ) {
    _mobileTransfer = QuarkMobileTransfer(
      this.http,
      webHeaders: () => headers(''),
      checkpoint: checkAccountContext,
      device: transferDevice ?? QuarkTransferDevice(),
      now: now,
      taskDelay: taskDelay,
    );
  }

  late final QuarkMobileTransfer _mobileTransfer;

  @override
  Future<List<String>> saveSharedFiles(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    String cookie,
  ) async {
    if (_mobileTransfer.device.supported &&
        QuarkShareTransfer.prefersMobile(s)) {
      checkAccountContext();
      try {
        final ids = await _mobileTransfer.save(s, files, target);
        DiagnosticLog.event(
          'Quark.share_transfer',
          fields: {'route': 'mobile'},
        );
        return ids;
      } on QuarkMobileUnavailable catch (error) {
        checkAccountContext();
        DiagnosticLog.event(
          'Quark.share_transfer_fallback',
          fields: {
            'from': 'mobile',
            'to': 'web',
            'stage': error.stage,
            'code': error.code,
            'status': error.status,
          },
        );
      }
    }
    final ids = await super.saveSharedFiles(s, files, target, cookie);
    DiagnosticLog.event('Quark.share_transfer', fields: {'route': 'web'});
    return ids;
  }

  static const webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 QuarkPC/6.0.8.649';
  static const cloudUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch';

  @override
  Future<Json> resolveFile(
    String fid,
    String name,
    String cookie, {
    bool forPlayback = false,
  }) => forPlayback
      ? QuarkPlaybackSource(
          http,
          headers: () => headers(cookie),
        ).resolve(fid, name)
      : super.resolveFile(fid, name, cookie);
}
