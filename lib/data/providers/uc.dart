import '../http.dart';
import '../state_store.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../domain/auth.dart';
import '../../domain/file_types.dart';
import '../../domain/download_network_policy.dart';
import '../../domain/uc_video_download.dart';
import '../../domain/public_share_route.dart';
import '../../diagnostics/app_log.dart';
import '../../download/hls.dart';
import 'cookie_cloud.dart';
import 'uc_tv.dart';

class UcConnector extends CookieCloudConnector {
  UcConnector(
    JsonHttp http, {
    CredentialStore? store,
    Duration taskDelay = const Duration(milliseconds: 750),
    int Function()? now,
    Future<void> Function(DownloadCleanup)? stageCleanup,
    bool Function(bool authenticated)? directShareDownloadEnabled,
  }) : tv = UcTvService(http, store: store, now: now),
       super(
         CloudPlatform.uc,
         http,
         store: store,
         taskDelay: taskDelay,
         now: now,
         stageCleanup: stageCleanup,
         webUserAgent: webUa,
         apiUserAgent: cloudUa,
         directShareDownloadEnabled: directShareDownloadEnabled,
       );

  final UcTvService tv;

  /// An explicit alternative to original-file download, using web playback
  /// permissions. Its size and identity belong to the selected transcode.
  Future<DownloadSpec> downloadPlayable(
    BrowseSession session,
    CloudFile file,
    Credential? credential, {
    String? resolution,
  }) async {
    require(
      !PublicShareRoute.uses(session) &&
          !file.isDirectory &&
          fileKind(file.name) == FileKind.video,
      '此功能仅支持 UC 视频文件',
    );
    if (credential == null) {
      throw const AccountLoginRequired('请先登录 UC 网盘，再下载可播放版本');
    }
    require(
      resolution == null || UcVideoDownload.labels.containsKey(resolution),
      'UC 下载画质信息无效，请重新选择',
    );
    return prepareStream(session, file, credential, (fid) async {
      final data = success(
        await http.postJsonRead(url('file/v2/play'), {
          'fid': fid,
          'resolutions': 'low,normal,high,super,2k,4k',
          'supports': 'fmp4_av,m3u8',
        }, headers('')),
      );
      RequestScope.checkpoint();
      require(
        (data.str('fid').isEmpty || data.str('fid') == fid) &&
            (file.size <= 0 ||
                data.integer('size') <= 0 ||
                data.integer('size') == file.size),
        'UC 返回的视频与所选文件不一致，请刷新列表后重试',
      );
      final choices = data.list('video_list').where((item) {
        final info = item.obj('video_info');
        final accessible = item['accessable'];
        return {true, 1, 'true', '1'}.contains(accessible) &&
            UcVideoDownload.labels.containsKey(item.str('resolution')) &&
            (resolution == null || item.str('resolution') == resolution) &&
            item.str('trans_status', 'success') == 'success' &&
            (item.str('supports_format') == 'mp4' || _hlsTrack(item)) &&
            info.str('hls_type', 'none') == 'none' &&
            info.str('url').isNotEmpty;
      }).toList();
      final ranks = UcVideoDownload.labels.keys.toList();
      choices.sort(
        (a, b) => ranks
            .indexOf(b.str('resolution'))
            .compareTo(ranks.indexOf(a.str('resolution'))),
      );
      require(
        choices.isNotEmpty,
        resolution == null
            ? 'UC 暂未提供可下载的可播放版本，请稍后重试或尝试原文件下载'
            : 'UC 原选画质已不可用，无法续传；请重新选择可播放版本',
      );
      final chosen = choices.first, info = chosen.obj('video_info');
      final address = info.str('url'), uri = Uri.tryParse(address);
      require(
        uri != null &&
            uri.scheme == 'https' &&
            uri.userInfo.isEmpty &&
            (uri.host == 'uc.cn' || uri.host.endsWith('.uc.cn')),
        'UC 未返回有效的可播放版本下载地址',
      );
      final downloadHeaders = {...headers(''), 'Accept-Encoding': 'identity'};
      var format = 'mp4';
      DownloadNetworkPolicy? policy;
      if (_hlsTrack(chosen)) {
        // HLS segment requests also carry the web session. Keep every URL and
        // redirect inside UC's HTTPS hosts, including after task restoration.
        policy = DownloadNetworkPolicy.fromJson({
          'hosts': ['uc.cn', '*.uc.cn'],
          'schemes': ['https'],
          'ports': [443],
        });
        policy.checkedUrl(address);
        final playlist = await probeDownload(
          address,
          downloadHeaders,
          followRedirects: false,
          maxBytes: 512 * 1024,
        );
        require(
          playlist.successful &&
              {
                '',
                'identity',
              }.contains(playlist.header('content-encoding').toLowerCase()),
          'UC 可播放版本连接失败（HTTP ${playlist.status}），请重试',
        );
        require(
          !playlist.body.contains('#EXT-X-STREAM-INF') &&
              playlist.body.trimRight().endsWith('#EXT-X-ENDLIST'),
          'UC 视频播放列表不完整或格式不支持，请稍后重试',
        );
        final media = HlsPlaylist.media(address, playlist.body);
        for (final url in media.urls) {
          policy.checkedUrl(url);
        }
        format = media.fragmentedMp4 ? 'hls_mp4' : 'hls_ts';
      }
      final quality = UcVideoDownload.fromJson({
        'resolution': chosen.str('resolution'),
        'width': info['width'],
        'height': info['height'],
        'size': info['size'],
        'format': format,
      });
      // Keep account cookies on the returned UC node; a redirect must be
      // resolved again instead of forwarding credentials to an unknown host.
      if (!quality.segmented) {
        final probe = await probeDownload(
          address,
          downloadHeaders,
          followRedirects: false,
        );
        require(probe.successful, 'UC 可播放版本连接失败（HTTP ${probe.status}），请重试');
        final range = RegExp(
          r'^bytes 0-0/(\d+)$',
        ).firstMatch(probe.header('content-range'));
        final length = int.tryParse(probe.header('content-length'));
        final total =
            probe.status == 206 &&
                range != null &&
                (length == null || length == 1)
            ? int.tryParse(range.group(1)!)
            : probe.status == 200
            ? length
            : null;
        final encoding = probe.header('content-encoding').toLowerCase();
        require(
          (encoding.isEmpty || encoding == 'identity') && total == quality.size,
          'UC 可播放版本的实际大小不一致，请重新获取下载链接',
        );
      }
      DiagnosticLog.event(
        'uc.playable_download',
        fields: {'file': DiagnosticLog.reference(file.id), ...quality.toJson()},
      );
      return DownloadSpec(
        url: address,
        fileName: quality.fileName(file.name),
        // The API's estimate can differ from the assembled HLS container size.
        expectedSize: quality.segmented ? 0 : quality.size,
        headers: downloadHeaders,
        source: {'ucVideo': quality.toJson()},
        networkPolicy: policy,
      );
    }, forPlayback: false);
  }

  static bool _hlsTrack(Json item) {
    final info = item.obj('video_info');
    return {
          'm3u8',
          'fmp4',
          'fmp4_av',
          'p_qv',
        }.contains(item.str('supports_format')) &&
        (info.str('format') == 'm3u8' || info.str('file_format') == 'm3u8') &&
        Uri.tryParse(info.str('url'))?.path.toLowerCase().endsWith('.m3u8') ==
            true;
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    if (session.mode != BrowseMode.share) {
      return _accountDownload(session, file, credential);
    }
    require(!file.isDirectory, '文件夹不能直接下载');
    if (credential == null) return _guestDownload(session, file);
    final owner = tv.store?.credential(CloudPlatform.uc);
    final boundRevision = owner?.sameAs(credential) == true
        ? owner!.updatedAt
        : null;
    void checkpoint() {
      RequestScope.checkpoint();
      if (boundRevision != null) {
        require(
          tv.store!.credential(CloudPlatform.uc)?.updatedAt == boundRevision,
          'UC 账号已变化，请重新打开文件列表',
        );
      }
    }

    // Saved accounts always take priority. The guest setting only controls
    // recovery after the selected account's normal download route fails.
    try {
      return await _accountDownload(session, file, credential);
    } on AppException catch (error, stack) {
      checkpoint();
      if (!(directShareDownloadEnabled?.call(false) ?? true)) rethrow;
      DiagnosticLog.event(
        'share.download_fallback',
        fields: {
          'platform': 'uc',
          'stage': 'guest',
          'reason': error.runtimeType.toString(),
        },
      );
      try {
        final guest = await _guestDownload(session, file);
        checkpoint();
        return guest;
      } on AppException {
        checkpoint();
        // Keep the account's actionable login/authorization error when neither
        // route can supply the original file.
        Error.throwWithStackTrace(error, stack);
      }
    }
  }

  Future<DownloadSpec> _guestDownload(
    BrowseSession session,
    CloudFile file,
  ) async =>
      await tryShareDownload(session, file, null) ??
      (throw const AccountLoginRequired('UC 此文件不支持游客下载，请登录后重试'));

  Future<DownloadSpec> _accountDownload(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    Credential? authorized;
    var authorization = credential?.field('tv_status') == 'expired'
        ? 'expired'
        : 'not_configured';
    if (!file.isDirectory && UcTvService.authorized(credential)) {
      try {
        authorized = await tv.ensureAuthorized(credential!);
        authorization = 'available';
      } on UcTvAuthorizationRequired {
        RequestScope.checkpoint();
        authorization = 'refresh_rejected';
        // An expired optional grant must not prevent usable web downloads.
      }
    }
    DiagnosticLog.event(
      'uc.download_route',
      fields: {
        'platform': 'uc',
        'file': DiagnosticLog.reference(file.id),
        'route': authorized != null ? 'authorized_original' : 'web',
        'authorization': authorization,
      },
    );
    if (authorized != null) {
      final current = authorized;
      return prepareStream(
        session,
        file,
        current,
        (fid) => tv.download(current, fid, file),
        forPlayback: false,
      );
    }
    try {
      return await downloadFallback(session, file, credential);
    } on UcOriginalContentMismatch catch (error) {
      throw UcTvAuthorizationRequired(
        '${error.message}。可尝试「TV 播放授权」后重试原文件，或选择「下载可播放版本」',
      );
    }
  }

  @override
  Future<DownloadSpec> playback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    if (fileKind(file.name) != FileKind.video) {
      return super.playback(session, file, credential);
    }
    if (credential == null) {
      throw const AccountLoginRequired('请先完成 UC 网页登录，再授权 TV 播放');
    }
    // Check the grant before creating a temporary share-transfer directory.
    final current = await tv.ensureAuthorized(credential);
    return prepareStream(
      session,
      file,
      current,
      (fid) => tv.playback(current, fid, file.name),
    );
  }

  static const webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const cloudUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.6.1 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch';
}
