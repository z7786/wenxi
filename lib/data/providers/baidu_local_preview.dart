import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' show RC4Engine, KeyParameter;
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../http.dart';
import 'baidu_link_service.dart';

/// Account preview resolution runs on the device with per-request state.
class BaiduLocalPreview {
  BaiduLocalPreview(this.http);
  final JsonHttp http;

  Future<BaiduResolvedLink> resolve({
    required String cookie,
    required String path,
    required String fileId,
    required String appId,
    required Json device,
  }) => _PreviewRequest(http, cookie, path, fileId, appId, device).resolve();
}

class _PreviewRequest {
  _PreviewRequest(
    this.http,
    this.cookie,
    this.path,
    this.fileId,
    String appId,
    Json device,
  ) : appId = appId.ifEmpty('250528'),
      device = Map.unmodifiable({...device});

  static const _version = '13.15.4';
  static const _sapiKey = '0c2d71b9d3aee3947c59a7480df05e85';
  final JsonHttp http;
  final String cookie, path, fileId, appId;
  final Json device;
  String get bduss => LoginCredentials.cookiePairs(cookie)['BDUSS'] ?? '';
  String get id => device.str('id');
  String get model => device.str('model').ifEmpty('AsterLink');
  String get release => device.str('osVersion').ifEmpty('13');
  String get downloadVersion => device.str('downloadVersion').ifEmpty(_version);
  String get channel => 'android_${release}_${model}_bd-netdisk_1';
  String agent([String version = _version]) =>
      'netdisk;$version;${Uri.encodeQueryComponent(model)};android-android;'
      '${Uri.encodeQueryComponent(release)};JSbridge4.4.0;jointBridge;1.1.0;';

  Map<String, Object?> get parameters {
    final network = device.str('networkType').toLowerCase();
    final valid = RegExp(r'^[a-z0-9._-]{1,64}$').hasMatch(network);
    const apns = {
      'wifi': 1,
      '3gnet': 21,
      '3gwap': 22,
      'cmnet': 31,
      'uninet': 32,
      'ctnet': 33,
      'cmwap': 41,
      'uniwap': 42,
      'ctwap': 43,
    };
    return {
      'devuid': id,
      'cuid': id,
      'freeisp': 0,
      'queryfree': 2,
      'apn_id': valid
          ? '${apns[network] ?? 0}_${device.integer('networkSubtype').clamp(0, 100)}'
          : '0_0',
      if (valid) 'network_type': network,
    };
  }

  Map<String, Object?> get base => {
    ...parameters,
    'app_id': appId,
    'clienttype': 1,
    'version': _version,
    'channel': '',
    'bdstoken': md5.convert(utf8.encode(bduss)).toString(),
  };

  static String sortedForm(Map<String, Object?> data) {
    final keys = data.keys.toList()..sort();
    return form({
      for (final key in keys) key: data[key],
    }).replaceAll('%7E', '~');
  }

  Future<Json> request(
    String endpoint, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
    String? userAgent,
    bool allowMissingCode = false,
  }) async {
    RequestScope.checkpoint();
    final response = await http.request(
      body == null ? 'GET' : 'POST',
      query.isEmpty ? endpoint : '$endpoint?${sortedForm(query)}',
      body: body == null ? null : sortedForm(body),
      headers: {'Cookie': cookie, 'User-Agent': userAgent ?? agent()},
      contentType: body == null
          ? null
          : 'application/x-www-form-urlencoded; charset=utf-8',
      followRedirects: false,
    );
    RequestScope.checkpoint();
    if (response.status == 401) {
      throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
    }
    if (!response.successful) {
      throw HttpRequestFailure(
        '百度本地取链暂不可用，请稍后重试',
        kind: 'baidu_local_http',
        status: response.status,
        retryable: {408, 429, 500, 502, 503, 504}.contains(response.status),
      );
    }
    require(response.body.length <= 2 * 1024 * 1024, '百度本地取链响应过大');
    final data = response.json;
    final rawCode = data['errno'] ?? data['error_code'];
    require(rawCode != null || allowMissingCode, '百度本地取链响应缺少状态');
    if (rawCode != null) {
      require(
        rawCode is int ||
            rawCode is String && RegExp(r'^-?\d+$').hasMatch(rawCode),
        '百度本地取链响应状态无效',
      );
      final code = int.parse('$rawCode');
      if (code == -6) {
        throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
      }
      if (code != 0) {
        throw const HttpRequestFailure(
          '百度本地取链失败，请稍后重试',
          kind: 'baidu_local_upstream',
          retryable: true,
        );
      }
    }
    return data;
  }

  Future<BaiduResolvedLink> resolve() async {
    RequestScope.checkpoint();
    require(
      cookie.length <= 32768 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(cookie),
      '百度登录信息无效',
    );
    if (bduss.isEmpty) throw const AccountLoginRequired('请先登录百度网盘');
    require(
      RegExp(r'^[a-fA-F0-9]{32}\|0$').hasMatch(id) &&
          model.length <= 128 &&
          release.length <= 32 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch('$model$release') &&
          {_version, '12.1.3'}.contains(downloadVersion),
      '百度客户端参数无效',
    );
    final numericId = RegExp(r'^\d{1,32}$').hasMatch(fileId);
    require(
      RegExp(r'^\d{1,32}$').hasMatch(appId) &&
          (path.startsWith('/') || numericId) &&
          path.length <= 8192 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(path),
      '百度文件标识无效',
    );
    if (path.startsWith('/')) {
      var vip = '';
      try {
        final member = await request(
          'https://pan.baidu.com/rest/2.0/xpan/nas',
          query: {...base, 'method': 'uinfo'},
        );
        if ({'0', '1', '2'}.contains(member.str('vip_type'))) {
          vip = member.str('vip_type');
        }
      } on AccountLoginRequired {
        rethrow;
      } catch (_) {
        RequestScope.checkpoint();
      }
      try {
        return BaiduResolvedLink(
          url: await locate(await preview(vip)),
          preview: true,
        );
      } on AccountLoginRequired {
        rethrow;
      } catch (_) {
        RequestScope.checkpoint();
      }
      try {
        return BaiduResolvedLink(
          url: await locate({if (vip.isNotEmpty) 'vip': vip}),
        );
      } on AccountLoginRequired {
        rethrow;
      } catch (_) {
        RequestScope.checkpoint();
        if (!numericId) rethrow;
      }
    }
    final data = await request(
      'https://pan.baidu.com/api/filemetas',
      query: {
        ...base,
        'dlink': 1,
        'fsids': jsonEncode([fileId]),
      },
      userAgent: agent(downloadVersion),
    );
    final entries = data.list('info');
    final matching = entries.where((e) => e.str('fs_id') == fileId).firstOrNull;
    final entry =
        matching ??
        (entries.length == 1 && entries.single.str('fs_id').isEmpty
            ? entries.single
            : null);
    final url = entry?.str('dlink') ?? '';
    require(_allowedUrl(url), '百度没有返回可用下载链接');
    return BaiduResolvedLink(url: url);
  }

  Future<Map<String, Object?>> preview(String vip) async {
    final identityForm = <String, Object?>{
      'bduss': bduss,
      'client': 'android',
      'tpl': 'netdisk',
      'appid': 1,
      'app_version': _version,
      'sdk_version': '9.0.0.0.3',
      'sdkversion': '9.0.0.0.3',
      'clientid': id,
      'cuid': id,
    };
    identityForm['sig'] = md5
        .convert(utf8.encode('${sortedForm(identityForm)}&sign_key=$_sapiKey'))
        .toString();
    final identity = await request(
      'https://passport.baidu.com/v2/sapi/center/getuinfo',
      body: identityForm,
      userAgent: 'tpl:netdisk;android_sapi_v9.0.0.0.3',
    );
    final uid = identity.str('uid').ifEmpty(identity.str('userid'));
    require(RegExp(r'^\d{1,32}$').hasMatch(uid), '百度预览会话暂不可用');
    final activation = await request(
      'https://pan.baidu.com/api/report/user',
      query: {
        ...base,
        'channel': channel,
        'action': 'ANDROID_ACTIVE_FRONTDESK',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        if (vip.isNotEmpty) 'vip': vip,
      },
    );
    final encoded = activation.str('uinfo');
    require(encoded.isNotEmpty && encoded.length <= 4096, '百度预览会话暂不可用');
    final cipher = RC4Engine()
      ..init(false, KeyParameter(Uint8List.fromList(utf8.encode(uid))));
    final bytes = cipher.process(base64Decode(encoded));
    try {
      final secret = utf8.decode(bytes);
      require(secret.isNotEmpty, '百度预览会话暂不可用');
      final stamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      final hash = sha1.convert(utf8.encode(bduss)).toString();
      return {
        ...parameters,
        'channel': channel,
        'time': stamp,
        'rand': sha1
            .convert(utf8.encode('$hash$uid$secret$stamp$id'))
            .toString(),
        'use': 1,
        if (vip.isNotEmpty) 'vip': vip,
      };
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<String> locate(Map<String, Object?> extra) async {
    final data = await request(
      'https://d.pcs.baidu.com/rest/2.0/pcs/file',
      query: {
        ...base,
        'method': 'locatedownload',
        'ver': '2.0',
        'check_blue': 1,
        'esl': 1,
        'dtype': 0,
        'ehps': 1,
        'path': path,
        ...extra,
      },
      userAgent: agent(downloadVersion),
      allowMissingCode: true,
    );
    String? fallback;
    for (final item in data.list('urls')) {
      if (item.containsKey('encrypt') && item.str('encrypt') != '0') continue;
      final url = item.str('url');
      if (!_allowedUrl(url)) continue;
      if (url.startsWith('https:')) return url;
      fallback ??= url;
    }
    require(fallback != null, '百度没有返回可用下载链接');
    return fallback!;
  }
}

bool _allowedUrl(String value) {
  final uri = Uri.tryParse(value);
  final host = uri?.host.toLowerCase() ?? '';
  return uri != null &&
      {'https', 'http'}.contains(uri.scheme) &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment &&
      !RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value) &&
      [
        'baidu.com',
        'baidupcs.com',
        'baidubce.com',
      ].any((d) => host == d || host.endsWith('.$d'));
}
