import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../http.dart';

class UcTvQrCode {
  const UcTvQrCode(this.queryToken, this.image, this.expiresAt);
  final String queryToken;
  final Uint8List image;
  final int expiresAt;
}

class UcTvTokens {
  const UcTvTokens(this.access, this.refresh, this.expiresAt);
  final String access, refresh;
  final int expiresAt;
}

/// UC's TV protocol is separate from the Cookie-based web connector.
/// Only the token exchange uses Extscreen, over HTTPS without redirects.
class UcTvProtocol {
  UcTvProtocol(this.http, {int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final JsonHttp http;
  final int Function() now;
  static const api = 'https://open-api-drive.uc.cn';
  static const tokenApi = 'https://api.extscreen.com/ucdrive/token';
  static const clientId = '5acf882d27b74502b7040b0c65519aa7';
  static const _signKey = 'l3srvtd7p42l0d0x1u8d7yc8ye9kki4d';
  static const userAgent =
      'Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1';

  static bool validSecret(String value) =>
      value.isNotEmpty &&
      value.length <= 16384 &&
      !RegExp(r'[\s\x00-\x1f\x7f-\x9f]').hasMatch(value);

  static bool validDevice(String value) =>
      RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(value);

  Map<String, String> _deviceParameters(String device, int timestamp) {
    require(validDevice(device), 'UC TV 设备信息无效，请重新扫码');
    return {
      'req_id': md5.convert(utf8.encode('$device$timestamp')).toString(),
      'app_ver': '1.7.2.2',
      'device_id': device,
      'device_brand': 'Xiaomi',
      'platform': 'tv',
      'device_name': 'M2004J7AC',
      'device_model': 'M2004J7AC',
      'build_device': 'M2004J7AC',
      'build_product': 'M2004J7AC',
      'device_gpu': 'Adreno (TM) 550',
      'activity_rect': '{}',
      'channel': 'UCTVOFFICIALWEB',
    };
  }

  Future<HttpResult> _get(
    String path,
    String device,
    Map<String, String> extra, {
    String access = '',
  }) async {
    RequestScope.checkpoint();
    final timestamp = now();
    final result = await http.request(
      'GET',
      query('$api$path', {
        ..._deviceParameters(device, timestamp),
        if (access.isNotEmpty) 'access_token': access,
        ...extra,
      }),
      headers: {
        'Accept': 'application/json, text/plain, */*',
        'User-Agent': userAgent,
        'x-pan-tm': '$timestamp',
        'x-pan-token': sha256
            .convert(utf8.encode('GET&$path&$timestamp&$_signKey'))
            .toString(),
        'x-pan-client-id': clientId,
      },
      followRedirects: false,
    );
    RequestScope.checkpoint();
    return result;
  }

  static bool _success(HttpResult response, Json data) =>
      response.successful &&
      data.containsKey('status') &&
      {0, 200}.contains(data.integer('status', -1)) &&
      data.integer('errno') == 0;

  static bool _expired(HttpResult response, Json data) =>
      response.status == 401 || {10001, 11001}.contains(data.integer('errno'));

  static Json _data(HttpResult response, String message) {
    final json = response.json;
    if (_expired(response, json)) {
      throw const UcTvAuthorizationRequired('UC TV 播放授权已失效，请重新扫码');
    }
    require(_success(response, json), message);
    return json;
  }

  Future<UcTvQrCode> authorize(String device) async {
    final response = await _get('/oauth/authorize', device, {
      'auth_type': 'code',
      'client_id': clientId,
      'scope': 'netdisk',
      'qrcode': '1',
      'qr_width': '460',
      'qr_height': '460',
    });
    final data = _data(response, '获取 UC TV 授权二维码失败，请重试');
    final token = data.str('query_token');
    require(validSecret(token), 'UC 未返回有效授权凭据，请重新获取二维码');
    var raw = data.str('qr_data');
    require(raw.length <= 512 * 1024, 'UC 返回的二维码数据过大，请重试');
    if (raw.startsWith('data:')) {
      require(
        RegExp(
          r'^data:image/(?:png|jpe?g);base64,',
          caseSensitive: false,
        ).hasMatch(raw),
        'UC 返回的二维码格式无效，请重试',
      );
      raw = raw.substring(raw.indexOf(',') + 1);
    }
    Uint8List image;
    try {
      image = base64Decode(raw.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw const AppException('UC 返回的二维码数据无效，请重试');
    }
    final png =
        image.length > 24 &&
        image.take(8).join(',') == '137,80,78,71,13,10,26,10';
    final jpeg =
        image.length > 4 &&
        image[0] == 0xff &&
        image[1] == 0xd8 &&
        image[2] == 0xff;
    require(png || jpeg, 'UC 返回的二维码图片无效，请重试');
    final lifetime = data.integer('expires_in', 300).clamp(1, 600);
    return UcTvQrCode(token, image, now() + lifetime * 1000);
  }

  /// Null means UC has not received the user's confirmation yet.
  Future<String?> pollCode(String device, String queryToken) async {
    require(validSecret(queryToken), '二维码已失效，请重新获取');
    final response = await _get('/oauth/code', device, {
      'client_id': clientId,
      'scope': 'netdisk',
      'query_token': queryToken,
    });
    final data = response.json;
    // Confirmed against the live official API: HTTP 400 / errno 11003.
    if (data.integer('errno') == 11003) return null;
    require(_success(response, data), '二维码已失效或授权未完成，请重新获取');
    final code = data.str('code');
    if (code.isEmpty) return null;
    require(validSecret(code), 'UC 返回的授权码无效，请重新扫码');
    return code;
  }

  Future<UcTvTokens> exchange(
    String device, {
    String code = '',
    String refresh = '',
  }) async {
    require(
      code.isEmpty != refresh.isEmpty && validSecret(code.ifEmpty(refresh)),
      'UC TV 授权信息不完整，请重新扫码',
    );
    RequestScope.checkpoint();
    final response = await http.request(
      'POST',
      tokenApi,
      body: encoded({
        ..._deviceParameters(device, now()),
        if (code.isNotEmpty) 'code': code,
        if (refresh.isNotEmpty) 'refresh_token': refresh,
      }),
      headers: const {'Accept': 'application/json', 'User-Agent': userAgent},
      contentType: 'application/json; charset=utf-8',
      followRedirects: false,
    );
    RequestScope.checkpoint();
    final outer = response.json, data = outer.obj('data');
    if (refresh.isNotEmpty &&
        (_expired(response, data) ||
            data.integer('errno') == 11000 ||
            outer.integer('code') == 401)) {
      throw const UcTvAuthorizationRequired('UC TV 播放授权已失效，请重新扫码');
    }
    require(
      response.successful &&
          outer.integer('code') == 200 &&
          {0, 200}.contains(data.integer('status', -1)) &&
          data.integer('errno') == 0,
      refresh.isEmpty
          ? 'UC TV 授权交换失败，请重新扫码；若持续失败，请稍后重试'
          : 'UC TV 授权续期失败，请稍后重试或重新扫码',
    );
    final access = data.str('access_token');
    final renewed = data.str('refresh_token').ifEmpty(refresh);
    final lifetime = data.integer('expires_in');
    require(
      validSecret(access) &&
          validSecret(renewed) &&
          lifetime > 0 &&
          lifetime <= 366 * 24 * 60 * 60,
      'UC TV 返回的授权信息不完整，请重新扫码',
    );
    return UcTvTokens(access, renewed, now() + lifetime * 1000);
  }

  Future<Json> userInfo(String device, String access) async {
    require(validSecret(access), 'UC TV 授权信息无效');
    final data = _data(
      await _get('/user', device, {'method': 'user_info'}, access: access),
      'UC TV 账号验证失败，请重新扫码',
    );
    // The authenticated /user status is the validation result. Nickname data
    // is optional and must not turn a valid grant into a failed login.
    return data.obj('data');
  }

  Future<DownloadSpec> streaming(
    String device,
    String access,
    String fid,
    String name,
  ) async {
    require(validSecret(access) && fid.isNotEmpty, 'UC TV 播放信息不完整');
    final json = _data(
      await _get('/file', device, {
        'method': 'streaming',
        'group_by': 'source',
        'fid': fid,
        'resolution': 'low,normal,high,super,2k,4k',
        'support': 'dolby_vision',
      }, access: access),
      'UC TV 无法读取此视频，请确认扫码账号与网页登录一致，并在 UC 中检查视频是否可播放',
    );
    final data = json.obj('data');
    require(
      data.str('fid').isEmpty || data.str('fid') == fid,
      'UC TV 返回的视频与所选文件不一致，请刷新列表',
    );
    require(data['video_info'] is List, 'UC TV 尚未返回视频画质，请稍后重试');
    const ranks = {
      'low': 1,
      'normal': 2,
      'high': 3,
      'super': 4,
      '2k': 5,
      '4k': 6,
    };
    final available = data.list('video_info').where((item) {
      final uri = Uri.tryParse(item.str('url'));
      return uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          (!item.containsKey('accessable') ||
              item.integer('accessable') == 1) &&
          (item.str('fid').isEmpty || item.str('fid') == fid);
    }).toList();
    require(available.isNotEmpty, 'UC TV 暂无可播放画质，请在 UC 中确认转码进度和播放权限');
    available.sort((a, b) {
      final rank = (ranks[b.str('resolution')] ?? 0).compareTo(
        ranks[a.str('resolution')] ?? 0,
      );
      if (rank != 0) return rank;
      final pixels = (b.integer('width') * b.integer('height')).compareTo(
        a.integer('width') * a.integer('height'),
      );
      return pixels != 0
          ? pixels
          : b.number('bitrate').compareTo(a.number('bitrate'));
    });
    final selected = available.first;
    return DownloadSpec(
      url: selected.str('url'),
      fileName: name,
      expectedSize: selected.integer('size') > 0 ? selected.integer('size') : 0,
      // The signed stream authorizes itself. Never forward web Cookies or TV
      // access tokens to a media CDN, or reuse the original file's checksum.
      headers: const {},
    );
  }

  Future<DownloadSpec> download(
    String device,
    String access,
    String fid,
    CloudFile file, {
    String Function()? currentCookie,
  }) async {
    require(validSecret(access) && fid.isNotEmpty, 'UC 原文件下载授权信息不完整');
    final json = _data(
      await _get('/file', device, {
        'method': 'download',
        'group_by': 'source',
        'fid': fid,
        'resolution': 'low,normal,high,super,2k,4k',
        'support': 'dolby_vision',
      }, access: access),
      'UC 无法取得原文件，请确认授权账号与网页登录一致，并检查该文件的下载权限',
    );
    final data = json.obj('data');
    require(data.str('fid') == fid, 'UC 返回的下载文件与所选文件不一致，请刷新列表');
    final size = int.tryParse(data.str('size'));
    require(
      size != null && size >= 0 && (file.size <= 0 || size == file.size),
      'UC 返回的原文件大小与列表不一致，请刷新列表后重试',
    );
    final url = data.str('download_url');
    final uri = Uri.tryParse(url);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      'UC 未返回有效的原文件下载地址',
    );

    // UC's original-file nodes use the web account for authenticated Range
    // requests. Keep these credentials off the TV API and foreign CDN hosts.
    final headers = <String, String>{};
    if (uri!.host == 'uc.cn' || uri.host.endsWith('.uc.cn')) {
      final cookie = currentCookie?.call() ?? '';
      if (cookie.isNotEmpty) {
        headers['Cookie'] = LoginCredentials.normalize(
          CloudPlatform.uc,
          cookie,
        );
      }
    }

    // The download endpoint is distinct from streaming. Verify its actual
    // object too, including files without an extension, before handing it off.
    final probe = await http.peek(url, {
      ...headers,
      'Accept-Encoding': 'identity',
    }, maxBytes: 2);
    RequestScope.checkpoint();
    final encoding = probe.header('content-encoding').toLowerCase();
    final length = int.tryParse(probe.header('content-length'));
    final range = RegExp(
      r'^bytes 0-(\d+)/(\d+)$',
    ).firstMatch(probe.header('content-range'));
    int? total;
    if (probe.status == 206 && range != null) {
      final end = int.tryParse(range.group(1)!);
      final remoteSize = int.tryParse(range.group(2)!);
      if (remoteSize != null &&
          remoteSize > 0 &&
          end == (remoteSize == 1 ? 0 : 1) &&
          (length == null || length == end! + 1)) {
        total = remoteSize;
      }
    } else if (probe.status == 200 && length != null && length >= 0) {
      total = length;
    } else if (probe.status == 416 &&
        probe.header('content-range') == 'bytes */0') {
      total = 0;
    }
    final validResponse =
        (encoding.isEmpty || encoding == 'identity') && total != null;
    // Record only response metadata, never signed URLs, credentials, or body
    // bytes. A successful TV grant can still yield a replacement object.
    DiagnosticLog.event(
      'uc_tv.original_probe',
      fields: {
        'platform': 'uc',
        'file': DiagnosticLog.reference(fid),
        'route': 'authorized_original',
        'host': uri.host,
        'status': probe.status,
        'listedBytes': file.size,
        'expectedBytes': size,
        'receivedTotal': total,
        'responseBytes': length,
        'hasWebSession': headers.containsKey('Cookie'),
        'result': !validResponse
            ? 'invalid_response'
            : total == size
            ? 'matched'
            : 'size_mismatch',
      },
    );
    require(validResponse, 'UC 原文件长度检查失败（HTTP ${probe.status}），请重试');
    require(
      total == size,
      'UC 授权下载返回的内容与原文件大小不一致，可能受到原站下载限制；可在文件菜单选择「下载可播放版本」，或使用 UC 官方客户端',
    );
    return DownloadSpec(
      url: url,
      fileName: file.name,
      expectedSize: total!,
      checksumType: file.hashType,
      checksumValue: file.hashValue,
      headers: headers,
    );
  }
}
