import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../diagnostics/app_log.dart';
import '../http.dart';

class BaiduResolvedLink {
  const BaiduResolvedLink({
    required this.url,
    this.preview = false,
    this.headers = const {},
    String? profile,
  }) : profile = profile ?? (preview ? 'baidu_preview' : 'baidu');

  final String url, profile;
  final bool preview;
  final Map<String, String> headers;
}

typedef BaiduLinkLookup =
    Future<BaiduResolvedLink> Function({
      required String cookie,
      required String path,
      required String fileId,
      required String appId,
      required Json device,
    });

/// 百度中转取链接口的客户端：使用当前 App 用户自己的账号请求下载地址。
/// 服务端核心实现因百度接口的特殊性暂不开源，避免公开后很快失效，后续视情况开放。
/// 服务地址、公钥及访问码通过本地构建配置注入，不在源码中填写生产密钥。
class BaiduLinkService {
  BaiduLinkService(
    this.http, {
    this.endpoint = const String.fromEnvironment('ASTERLINK_BAIDU_API_URL'),
    this.publicKey = const String.fromEnvironment(
      'ASTERLINK_BAIDU_API_PUBLIC_KEY',
    ),
    this.accessKey = const String.fromEnvironment(
      'ASTERLINK_BAIDU_API_ACCESS_KEY',
    ),
  });
  final JsonHttp http;
  final String endpoint, publicKey, accessKey;

  Future<BaiduResolvedLink> resolve({
    required String cookie,
    required String path,
    required String fileId,
    required String appId,
    required Json device,
  }) async {
    final elapsed = Stopwatch()..start();
    RequestScope.checkpoint();
    final base = Uri.tryParse(endpoint);
    require(
      base != null &&
          {'http', 'https'}.contains(base.scheme) &&
          base.host.isNotEmpty &&
          base.userInfo.isEmpty &&
          !base.hasQuery &&
          !base.hasFragment &&
          publicKey.length >= 768 &&
          accessKey.isNotEmpty,
      '此版本未配置百度取链服务，请联系应用提供方',
    );
    final modulus = BigInt.tryParse(publicKey, radix: 16);
    require(modulus != null && modulus.bitLength >= 3072, '百度取链服务公钥无效');
    final key = CryptoBox.random(32), nonce = CryptoBox.random(12);
    final requestNonce = base64Encode(nonce);
    try {
      final rsa = OAEPEncoding.withSHA256(RSAEngine())
        ..init(
          true,
          PublicKeyParameter<RSAPublicKey>(
            RSAPublicKey(modulus!, BigInt.from(65537)),
          ),
        );
      final plain = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'accessKey': accessKey,
            'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'cookie': cookie,
            'path': path,
            'fileId': fileId,
            'appId': appId,
            'device': {...device, 'directDelivery': 1},
          }),
        ),
      );
      late Uint8List sealed;
      try {
        sealed = _crypt(true, key, nonce, plain, 'wenxi-link-v1/request');
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
      // A retry needs a fresh encrypted request, nonce and expiry timestamp.
      final result = await http.request(
        'POST',
        base!.resolve('v1/resolve').toString(),
        body: jsonEncode({
          'version': 1,
          'key': base64Encode(rsa.process(key)),
          'nonce': requestNonce,
          'data': base64Encode(sealed),
        }),
        headers: const {'Accept': 'application/json'},
        contentType: 'application/json',
        followRedirects: false,
      );
      RequestScope.checkpoint();
      if (!result.successful) {
        throw HttpRequestFailure(
          '百度取链服务连接失败（${result.status}），请稍后重试',
          kind: 'baidu_service',
          status: result.status,
          retryable: {408, 429, 500, 502, 503, 504}.contains(result.status),
        );
      }
      require(result.body.length <= 128 * 1024, '百度取链服务响应过大');
      Json data;
      try {
        final envelope = result.json;
        if (envelope.integer('version') != 1) throw const FormatException();
        final responseNonce = base64Decode(envelope.str('nonce'));
        if (responseNonce.length != 12) throw const FormatException();
        final decoded = _crypt(
          false,
          key,
          responseNonce,
          base64Decode(envelope.str('data')),
          'wenxi-link-v1/response/$requestNonce',
        );
        try {
          data = asJson(jsonDecode(utf8.decode(decoded)));
        } finally {
          decoded.fillRange(0, decoded.length, 0);
        }
      } catch (_) {
        throw const AppException('百度取链服务响应校验失败，请勿继续使用此连接');
      }
      if (!data.boolean('ok')) {
        final code = data.str('code');
        if (code == 'login_required') {
          throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
        }
        final message = switch (code) {
          'unauthorized' => '百度取链服务授权不匹配，请更新应用',
          'clock' => '设备时间有误，请校准系统时间',
          'invalid_request' => '百度文件或账号参数无效，请刷新列表',
          'client_update' => '请更新应用后使用百度取链服务',
          _ => '百度取链服务暂不可用，请稍后重试',
        };
        throw HttpRequestFailure(
          message,
          kind: 'baidu_service_$code',
          retryable: {'upstream', 'replayed'}.contains(code),
        );
      }
      final requestedVersion = device.str('downloadVersion');
      require(
        requestedVersion.isEmpty ||
            data.str('downloadVersion') == requestedVersion,
        '百度取链服务与当前应用不兼容，请联系服务提供方更新服务',
      );
      final uri = Uri.tryParse(data.str('url'));
      final host = uri?.host.toLowerCase() ?? '';
      require(
        uri != null &&
            {'https', 'http'}.contains(uri.scheme) &&
            uri.userInfo.isEmpty &&
            [
              'baidu.com',
              'baidupcs.com',
              'baidubce.com',
            ].any((domain) => host == domain || host.endsWith('.$domain')) &&
            {
              'baidu',
              'baidu_preview',
              'baidu_direct',
            }.contains(data.str('profile')),
        '百度取链服务返回的下载地址无效',
      );
      final profile = data.str('profile');
      final mediaHeaders = <String, String>{};
      if (profile == 'baidu_direct') {
        final raw = data['headers'];
        require(raw is Map && raw.length == 3, '百度取链服务返回的请求头无效');
        for (final entry in (raw as Map).entries) {
          require(
            entry.key is String && entry.value is String,
            '百度取链服务返回的请求头无效',
          );
          final name = (entry.key as String).toLowerCase();
          final value = entry.value as String;
          require(
            {'host', 'user-agent', 'accept-encoding'}.contains(name) &&
                !mediaHeaders.containsKey(name) &&
                value.length <= 256 &&
                !RegExp(r'[\x00-\x20\x7f]').hasMatch(value),
            '百度取链服务返回的请求头无效',
          );
          mediaHeaders[name] = value;
        }
        final deliveryHost = mediaHeaders['host'] ?? '';
        require(
          uri!.scheme == 'https' &&
              RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(deliveryHost) &&
              deliveryHost.endsWith('.baidu-int.com') &&
              mediaHeaders['user-agent'] == 'netdisk' &&
              mediaHeaders['accept-encoding'] == 'identity',
          '百度取链服务返回的请求头无效',
        );
      } else {
        require(data['headers'] == null, '百度取链服务返回的请求头无效');
      }
      DiagnosticLog.event(
        'baidu.link_resolved',
        fields: {
          'profile': profile,
          'host': host,
          'elapsedMs': elapsed.elapsedMilliseconds,
        },
      );
      return BaiduResolvedLink(
        url: uri.toString(),
        preview: profile == 'baidu_preview',
        profile: profile,
        headers: Map.unmodifiable(mediaHeaders),
      );
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  Uint8List _crypt(
    bool encrypt,
    Uint8List key,
    Uint8List nonce,
    Uint8List data,
    String aad,
  ) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        encrypt,
        AEADParameters(
          KeyParameter(key),
          128,
          nonce,
          Uint8List.fromList(utf8.encode(aad)),
        ),
      );
    return cipher.process(data);
  }
}
