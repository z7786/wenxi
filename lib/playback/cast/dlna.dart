import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../../core/json.dart';
import '../../lan/lan_models.dart' show isLanAddress;

String xmlText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _child(XmlElement node, String name) =>
    node.childElements
        .where((e) => e.name.local == name)
        .firstOrNull
        ?.innerText
        .trim() ??
    '';

bool castEndpoint(Uri uri) =>
    uri.scheme == 'http' &&
    uri.userInfo.isEmpty &&
    isLanAddress(uri.host) &&
    !uri.hasFragment &&
    uri.port > 0;

class CastService {
  const CastService(this.type, this.control);
  final String type;
  final Uri control;
}

class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    required this.description,
    required this.transport,
    this.rendering,
    this.model = '',
  });
  final String id, name, model;
  final Uri description;
  final CastService transport;
  final CastService? rendering;

  static CastDevice? parse(String text, Uri location) {
    require(castEndpoint(location), '电视地址无效，请连接同一局域网');
    final doc = XmlDocument.parse(text);
    final baseText = doc.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'URLBase')
        .firstOrNull
        ?.innerText
        .trim();
    final base = baseText == null || baseText.isEmpty
        ? location
        : location.resolve(baseText);
    require(castEndpoint(base) && base.host == location.host, '电视返回了无效的服务地址');
    for (final node in doc.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'device',
    )) {
      final services = node.childElements
          .where((e) => e.name.local == 'serviceList')
          .expand((e) => e.childElements)
          .where((e) => e.name.local == 'service');
      CastService? service(String name) {
        for (final item in services) {
          final type = _child(item, 'serviceType');
          if (!RegExp(
            '^urn:schemas-upnp-org:service:$name:[0-9]+\$',
          ).hasMatch(type)) {
            continue;
          }
          final path = _child(item, 'controlURL');
          if (path.isEmpty) continue;
          final url = base.resolve(path);
          if (castEndpoint(url) && url.host == location.host) {
            return CastService(type, url);
          }
        }
        return null;
      }

      final transport = service('AVTransport');
      if (transport == null) continue;
      final name = _child(node, 'friendlyName');
      return CastDevice(
        id: _child(node, 'UDN').ifEmpty(location.toString()),
        name: name.ifEmpty('电视 · ${location.host}'),
        model: _child(node, 'modelName'),
        description: location,
        transport: transport,
        rendering: service('RenderingControl'),
      );
    }
    return null;
  }
}

class CastSoapException extends AppException {
  const CastSoapException(super.message, this.code);
  final int code;
  bool get unsupported => {401, 602, 710, 711}.contains(code);
}

String castMimeType(String name) {
  final path = Uri.tryParse(name)?.path.toLowerCase() ?? name.toLowerCase();
  if (path.endsWith('.m3u8')) return 'application/vnd.apple.mpegurl';
  if (path.endsWith('.mkv')) return 'video/x-matroska';
  if (path.endsWith('.ts') || path.endsWith('.m2ts')) return 'video/mp2t';
  if (path.endsWith('.avi')) return 'video/x-msvideo';
  if (path.endsWith('.webm')) return 'video/webm';
  if (path.endsWith('.mov')) return 'video/quicktime';
  return 'video/mp4';
}

String castTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 35999999);
  return '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:'
      '${(seconds % 60).toString().padLeft(2, '0')}';
}

Duration? parseCastTime(String? value) {
  final match = RegExp(
    r'^(\d+):(\d{2}):(\d{2})(?:\.\d+)?$',
  ).firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final h = int.tryParse(match[1]!);
  final m = int.parse(match[2]!), s = int.parse(match[3]!);
  if (h == null || h > 9999 || m > 59 || s > 59) return null;
  return Duration(hours: h, minutes: m, seconds: s);
}

/// One bounded HTTP client per discovery/session. It never follows redirects
/// or includes any cloud account headers in requests to a renderer.
class DlnaClient {
  DlnaClient({this.timeout = const Duration(seconds: 8)});
  final Duration timeout;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  bool _closed = false;

  Future<String> _read(HttpClientResponse response) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      bytes.add(chunk);
      require(bytes.length <= 1024 * 1024, '电视响应过大');
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<CastDevice?> describe(Uri uri) async {
    require(!_closed && castEndpoint(uri), '电视地址无效');
    final request = await _http.getUrl(uri).timeout(timeout);
    request.followRedirects = false;
    try {
      final response = await request.close().timeout(timeout);
      require(response.statusCode == 200, '无法读取电视信息，请确认电视已开启投屏');
      return CastDevice.parse(await _read(response).timeout(timeout), uri);
    } finally {
      request.abort();
    }
  }

  Future<Map<String, String>> action(
    CastService service,
    String name, [
    Map<String, String> arguments = const {},
  ]) async {
    require(!_closed && castEndpoint(service.control), '投屏连接已关闭');
    final request = await _http.postUrl(service.control).timeout(timeout);
    request.followRedirects = false;
    request.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    request.headers.set('SOAPAction', '"${service.type}#$name"');
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$name xmlns:u="${xmlText(service.type)}">'
        '${arguments.entries.map((e) => '<${e.key}>${xmlText(e.value)}</${e.key}>').join()}'
        '</u:$name></s:Body></s:Envelope>';
    request.add(utf8.encode(body));
    try {
      final response = await request.close().timeout(timeout);
      final text = await _read(response).timeout(timeout);
      final doc = XmlDocument.parse(text);
      final nodes = doc.descendants.whereType<XmlElement>();
      final fault = nodes.where((e) => e.name.local == 'Fault').firstOrNull;
      if (fault != null) {
        final code =
            int.tryParse(
              fault.descendants
                      .whereType<XmlElement>()
                      .where((e) => e.name.local == 'errorCode')
                      .firstOrNull
                      ?.innerText ??
                  '',
            ) ??
            0;
        final message = switch (code) {
          701 => '电视暂未就绪，请稍后重试',
          714 || 716 => '电视不支持此视频格式，请更换资源或使用本机播放',
          718 => '电视无法访问视频，请确认两台设备在同一局域网',
          401 || 602 || 710 || 711 => '这台电视不支持此操作，请使用电视遥控器',
          _ => '电视未能完成操作（$code），请重试',
        };
        throw CastSoapException(message, code);
      }
      require(
        response.statusCode >= 200 && response.statusCode < 300,
        '电视响应异常，请重新连接',
      );
      final result = nodes
          .where((e) => e.name.local == '${name}Response')
          .firstOrNull;
      require(result != null, '电视返回了无效的控制响应');
      return {
        for (final e in result!.childElements) e.name.local: e.innerText.trim(),
      };
    } on FormatException {
      throw const AppException('电视返回的信息无法识别，请重试');
    } finally {
      request.abort();
    }
  }

  Future<Map<String, String>> transport(
    CastDevice device,
    String actionName, [
    Map<String, String> args = const {},
  ]) => action(device.transport, actionName, {'InstanceID': '0', ...args});

  Future<void> setMedia(
    CastDevice device,
    String url,
    String title,
    String mime,
    Duration duration,
  ) async {
    final metadata =
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1"><dc:title>${xmlText(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:${xmlText(mime)}:*"'
        '${duration > Duration.zero ? ' duration="${castTime(duration)}"' : ''}>'
        '${xmlText(url)}</res></item></DIDL-Lite>';
    await transport(device, 'SetAVTransportURI', {
      'CurrentURI': url,
      'CurrentURIMetaData': metadata,
    });
  }

  void close() {
    _closed = true;
    _http.close(force: true);
  }
}
