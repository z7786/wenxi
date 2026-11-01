import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../http.dart';

class _VideoLinkUnavailable extends AppException {
  const _VideoLinkUnavailable(super.message);
}

/// Built-in Baidu App/DLNA video requests. API credentials and media headers
/// are separate; no account or signed URL is cached across playback requests.
class BaiduPlaybackClient {
  BaiduPlaybackClient(this.http, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  final JsonHttp http;
  final DateTime Function() clock;

  // These compatibility profiles match the independently verified video
  // requests. Changing the ordinary download client's version must not change
  // these fields or the DLNA signature's client identity.
  static const appUserAgent =
      'netdisk;13.35.7;24031PN0DC;android-android;12;JSbridge4.4.0;jointBridge;1.1.0;';
  static const mediaUserAgent =
      'com.android.chrome/131.0.6778.200 (Linux;Android 10) AndroidXMedia3/1.5.1';
  static const webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
  static const dlnaUserAgent = 'netdisk;P2SP;2.2.91.136;android-android;';
  static const _dlnaDevice = '73CED981D0F186D12BC18CAE1684FFD5|VSRCQTF6W';
  static const _dlnaVersion = '11.30.2';
  static const _redirects = {301, 302, 303, 307, 308};

  Future<DownloadSpec> personal(CloudFile file, String cookie) async {
    final path = file.token.ifEmpty(file.id.startsWith('/') ? file.id : '');
    require(path.startsWith('/'), '百度视频缺少文件路径，请刷新文件列表');
    AppException? failure;
    for (final alternate in [false, true]) {
      RequestScope.checkpoint();
      final parameters = alternate
          ? <String, Object?>{
              'type': 'VideoURL',
              'path': path,
              'fs_id': file.id,
              'devuid': '0%1',
              'clienttype': 1,
              'channel': 'android_15_25010PN30C_bd-netdisk_1523a',
              'nom3u8': 1,
              'dlink': 1,
              'media': 1,
              'origin': 'dlna',
            }
          : <String, Object?>{
              'type': 'M3U8_FLV_264_480',
              'path': path,
              'origin': 'dlna',
              'check_blue': 1,
              'app_id': 250528,
              'devuid':
                  '${newId().replaceAll('-', '').toUpperCase()}|'
                  '${newId().replaceAll('-', '').substring(0, 9).toUpperCase()}',
              'clienttype': 80,
              'channel': 'android_12_V2238A_bd-netdisk_1024266g',
              'network_type': 'wifi',
              'version': '12.11.9',
            };
      final route = alternate ? 'mediainfo_video_url' : 'mediainfo_dlna';
      final elapsed = Stopwatch()..start();
      try {
        final response = await http.request(
          'GET',
          query('https://pan.baidu.com/api/mediainfo', parameters),
          headers: {
            'Cookie': cookie,
            'User-Agent': alternate ? webUserAgent : appUserAgent,
            'Referer': 'https://pan.baidu.com/disk/main',
            'Accept': 'application/json, text/plain, */*',
          },
          followRedirects: false,
        );
        final data = _data(response);
        // A nonzero errno (and even HTTP 400) can accompany a usable dlink.
        // Only a bounded media read proves whether this address is playable.
        return await _media(
          _dlink(data, file.id),
          file,
          {
            'User-Agent': alternate ? 'netdisk' : mediaUserAgent,
            'Accept-Encoding': 'identity',
          },
          route: route,
          response: response,
          data: data,
          elapsed: elapsed,
        );
      } on _VideoLinkUnavailable catch (error) {
        failure = error;
      } on HttpRequestFailure catch (error) {
        if (!error.retryable) rethrow;
        failure = error;
      }
      RequestScope.checkpoint();
      DiagnosticLog.event(
        'baidu.video_link_fallback',
        fields: {'route': route},
      );
    }
    throw failure ?? const AppException('百度视频播放接口暂不可用，请稍后重试');
  }

  Future<DownloadSpec> share(
    BrowseSession session,
    CloudFile file, {
    required String cookie,
    required String sekey,
  }) async {
    final bduss = LoginCredentials.cookiePairs(cookie)['BDUSS'] ?? '';
    if (bduss.isEmpty) {
      throw const AccountLoginRequired('百度视频播放需要登录账号');
    }
    require(
      [
        session.meta('shareId'),
        session.meta('uk'),
        file.id,
      ].every((value) => RegExp(r'^[1-9]\d*$').hasMatch(value)),
      '百度分享视频信息不完整，请重新解析分享',
    );
    RequestScope.checkpoint();
    final elapsed = Stopwatch()..start();
    final user = _data(
      await http.request(
        'GET',
        query('https://mbd.baidu.com/userx/v1/info/get', {
          'appname': 'baiduboxapp',
          'fields': encoded(['uid']),
          'client': '',
          'clientfrom': '',
          'lang': 'zh-cn',
          'tpl': '',
          'ttt': '',
        }),
        headers: {
          'Cookie': cookie,
          'User-Agent': webUserAgent,
          'Accept': 'application/json, text/plain, */*',
        },
        followRedirects: false,
      ),
    );
    final uid = user.obj('data').obj('fields').str('uid');
    require(RegExp(r'^[1-9]\d*$').hasMatch(uid), '百度未返回账号 UID，请重新网页登录');
    final time = '${clock().millisecondsSinceEpoch}';
    String sha(String value) => sha1.convert(utf8.encode(value)).toString();
    final rand = sha(
      '${sha(bduss)}${uid}ebrcUYiuxaZv2XGu7KIYKxUrqfnOfpDF'
      '$time$_dlnaDevice${_dlnaVersion}ae5821440fab5e1a61a025f014bd8972',
    );
    final response = await http.request(
      'GET',
      query('https://pan.baidu.com/share/list', {
        'shareid': session.meta('shareId'),
        'uk': session.meta('uk'),
        'fid': file.id,
        'sekey': sekey,
        'origin': 'dlna',
        'devuid': _dlnaDevice,
        'clienttype': 1,
        'channel': 'android_12_zhao_bd-netdisk_1024266h',
        'version': _dlnaVersion,
        'time': time,
        'rand': rand,
      }),
      headers: {
        'Cookie': cookie,
        'User-Agent': dlnaUserAgent,
        'Referer': 'https://pan.baidu.com/',
        'Accept': 'application/json, text/plain, */*',
      },
      followRedirects: false,
    );
    final data = _data(response);
    require(
      data.integer('errno', data.integer('error_code')) == 0,
      '百度分享视频取链失败，请重新解析分享或稍后重试',
    );
    return _media(
      _dlink(data, file.id),
      file,
      const {
        'User-Agent': dlnaUserAgent,
        'Referer': 'https://pan.baidu.com/',
        'Accept-Encoding': 'identity',
      },
      route: 'share_dlna',
      response: response,
      data: data,
      elapsed: elapsed,
    );
  }

  Json _data(HttpResult result) {
    RequestScope.checkpoint();
    if (result.status == 401) {
      throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
    }
    require(result.body.length <= 512 * 1024, '百度视频接口响应过大');
    final Json data;
    try {
      data = result.json;
    } on AppException {
      throw _VideoLinkUnavailable('百度视频接口响应异常（HTTP ${result.status}）');
    }
    final code = data.integer('errno', data.integer('error_code'));
    if (code == -6) {
      throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
    }
    if ({-9, 31066}.contains(code)) {
      throw const AppException('百度视频文件或分享已失效，请刷新列表');
    }
    if (!result.successful && result.status != 400) {
      throw _VideoLinkUnavailable('百度视频接口暂不可用（HTTP ${result.status}）');
    }
    return data;
  }

  String _dlink(Json data, String fileId) {
    final entries = [
      if (data['info'] is Map) data.obj('info'),
      ...data.list('info'),
      ...data.list('list'),
      if (data['dlink'] is String) data,
    ];
    String id(Json item) => item.str('fs_id').ifEmpty(item.str('fid'));
    final identified = entries.where((entry) => id(entry).isNotEmpty).toList();
    if (identified.isNotEmpty) {
      require(
        identified.any((entry) => id(entry) == fileId),
        '百度返回的视频标识不一致，请刷新列表',
      );
    }
    final candidates = identified.isEmpty
        ? entries
        : identified.where((entry) => id(entry) == fileId);
    for (final entry in candidates) {
      final url = entry.str('dlink').trim();
      if (url.isNotEmpty) return _url(url).toString();
    }
    throw const _VideoLinkUnavailable('百度没有返回视频播放链接，请稍后重试');
  }

  Uri _url(String value) {
    final uri = Uri.tryParse(value);
    final host = uri?.host.toLowerCase() ?? '';
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.userInfo.isEmpty &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) &&
          [
            'baidu.com',
            'baidupcs.com',
            'baidubce.com',
          ].any((domain) => host == domain || host.endsWith('.$domain')),
      '百度返回的视频地址无效',
    );
    return uri!;
  }

  Future<DownloadSpec> _media(
    String address,
    CloudFile file,
    Map<String, String> headers, {
    required String route,
    required HttpResult response,
    required Json data,
    required Stopwatch elapsed,
  }) async {
    var uri = _url(address);
    for (var redirects = 0; redirects <= 5; redirects++) {
      RequestScope.checkpoint();
      final probe = await http.peek(
        uri.toString(),
        headers,
        maxBytes: 1024,
        followRedirects: false,
      );
      RequestScope.checkpoint();
      if (_redirects.contains(probe.status)) {
        final location = probe.header('location');
        require(location.isNotEmpty && redirects < 5, '百度视频地址跳转失败');
        final next = _url(uri.resolve(location).toString());
        require(uri.scheme != 'https' || next.scheme == 'https', '百度视频地址跳转无效');
        uri = next;
        continue;
      }
      if (!{200, 206}.contains(probe.status) || probe.body.isEmpty) {
        throw _VideoLinkUnavailable('百度视频地址暂不可用（HTTP ${probe.status}）');
      }
      final encoding = probe.header('content-encoding').trim().toLowerCase();
      if (encoding.isNotEmpty && encoding != 'identity') {
        throw const _VideoLinkUnavailable('百度视频地址未返回原始字节，请稍后重试');
      }
      final type = probe.header('content-type').toLowerCase();
      final text = probe.body.trimLeft();
      if (type.contains('text/html') ||
          type.contains('json') ||
          RegExp(
            r'^(?:<!doctype\s+html|<html\b|\{)',
            caseSensitive: false,
          ).hasMatch(text)) {
        throw const _VideoLinkUnavailable('百度视频地址返回了错误页面，请稍后重试');
      }
      final playlist = type.contains('mpegurl') || text.startsWith('#EXTM3U');
      var size = 0;
      if (!playlist) {
        if (probe.status == 206) {
          final range = RegExp(
            r'^bytes 0-(\d+)/(\d+)$',
            caseSensitive: false,
          ).firstMatch(probe.header('content-range'));
          require(range != null, '百度视频分段响应无效');
          size = int.parse(range![2]!);
          require(
            size > 0 && int.parse(range[1]!) == (size - 1).clamp(0, 1023),
            '百度视频分段响应无效',
          );
        } else {
          size = int.tryParse(probe.header('content-length')) ?? 0;
        }
        require(
          file.size <= 0 || size <= 0 || size == file.size,
          '百度视频大小已变化，请刷新文件列表',
        );
      }
      DiagnosticLog.event(
        'baidu.video_link_ready',
        fields: {
          'route': route,
          'apiStatus': response.status,
          'apiErrno': data.integer('errno', data.integer('error_code')),
          'host': uri.host,
          'playlist': playlist,
          'elapsedMs': elapsed.elapsedMilliseconds,
        },
      );
      // Keep the signed dispatcher so the existing stream proxy can resolve
      // a fresh CDN ticket when a redirected address expires during playback.
      return DownloadSpec(
        url: address,
        fileName: file.name,
        headers: headers,
        expectedSize: playlist
            ? 0
            : size > 0
            ? size
            : file.size,
        checksumType: playlist ? null : file.hashType,
        checksumValue: playlist ? null : file.hashValue,
        profile: 'baidu',
      );
    }
    throw const AppException('百度视频地址跳转过多');
  }
}
