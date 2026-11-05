import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../domain/c139_passcode.dart';

class C139PasscodeProtocol {
  // Compatibility key from the supplied 13.4.1 protocol sample.
  static const key = '2olBaQGYnEKoStYomsd1n7ax';
  static const maxResponseBytes = 8 * 1024 * 1024;
  static Json generalRequestData(C139Passcode code, String account) {
    require(account.isNotEmpty, '移动口令请求参数无效');
    require(code.code.isNotEmpty && code.code.length <= 128, '移动口令无效');
    return {
      'account': account,
      'linkCode': code.code,
      'linkCodeType': code.codeType,
      if (code.password?.isNotEmpty == true) 'passwd': code.password!,
      'isPasswd': 0,
    };
  }

  static Json requestData(
    C139Passcode code,
    String account, {
    String parent = 'root',
    int begin = 1,
    int end = 200,
  }) {
    require(
      account.isNotEmpty && parent.isNotEmpty && begin > 0 && end >= begin,
      '移动口令请求参数无效',
    );
    require(code.code.isNotEmpty && code.code.length <= 128, '移动口令无效');
    return {
      'account': account,
      'linkCode': code.code,
      'linkCodeType': code.codeType,
      if (code.password?.isNotEmpty == true) 'passwd': code.password!,
      'pCaID': parent,
      'caSrt': 0,
      'coSrt': 0,
      'srtDr': 0,
      'bNum': begin,
      'eNum': end,
      'isPasswd': 0,
    };
  }

  static String request(
    C139Passcode code,
    String account, {
    String parent = 'root',
    int begin = 1,
    int end = 200,
  }) {
    require(
      account.isNotEmpty && parent.isNotEmpty && begin > 0 && end >= begin,
      '移动口令请求参数无效',
    );
    require(code.code.isNotEmpty && code.code.length <= 128, '移动口令无效');
    final builder = XmlBuilder();
    builder.element(
      'getOutLinkInfoV6',
      nest: () {
        builder.element(
          'getOutLinkInfoReq',
          nest: () {
            builder.element('account', nest: account);
            for (final field in {
              'linkCode': code.code,
              if (code.password?.isNotEmpty == true) 'passwd': code.password!,
              'pCaID': parent,
            }.entries) {
              builder.element(field.key, nest: () => builder.text(field.value));
            }
            for (final field in {
              'linkCodeType': code.codeType,
              'caSrt': 0,
              'coSrt': 0,
              'srtDr': 0,
              'bNum': begin,
              'eNum': end,
              'isPasswd': 0,
            }.entries) {
              builder.element(field.key, nest: '${field.value}');
            }
          },
        );
      },
    );
    return builder.buildDocument().toXmlString();
  }

  static String encrypt(String plain, {Uint8List? iv}) {
    final nonce = iv ?? CryptoBox.random(16);
    require(nonce.length == 16, '移动口令加密参数无效');
    return base64Encode([
      ...nonce,
      ...CryptoBox.aesCbc(true, utf8.encode(plain), utf8.encode(key), nonce),
    ]);
  }

  static Json response(String body) {
    require(body.length <= maxResponseBytes, '移动口令响应过大');
    var plain = body.replaceFirst(RegExp(r'^\uFEFF'), '').trim();
    require(plain.isNotEmpty, '移动口令服务返回空响应，请稍后重试');
    if (!plain.startsWith('<') && !plain.startsWith('{')) {
      try {
        final raw = base64Decode(plain.replaceAll(RegExp(r'\s+'), ''));
        require(raw.length >= 32 && raw.length % 16 == 0, '移动口令响应无效');
        var decoded = CryptoBox.aesCbc(
          false,
          raw.sublist(16),
          utf8.encode(key),
          raw.sublist(0, 16),
        );
        if (decoded.length >= 2 && decoded[0] == 0x1f && decoded[1] == 0x8b) {
          // The trailer contains the uncompressed size, modulo 2^32. Also
          // enforce the limit while decoding rather than after allocation.
          require(decoded.length >= 18, '移动口令压缩响应无效');
          final size = ByteData.sublistView(
            decoded,
          ).getUint32(decoded.length - 4, Endian.little);
          require(size <= maxResponseBytes, '移动口令响应过大');
          final sink = _BoundedResponseSink(maxResponseBytes);
          final converter = gzip.decoder.startChunkedConversion(sink);
          converter.add(decoded);
          converter.close();
          decoded = sink.bytes;
        }
        plain = utf8
            .decode(decoded)
            .replaceFirst(RegExp(r'^\uFEFF'), '')
            .trim();
      } on AppException {
        rethrow;
      } catch (_) {
        throw const AppException('移动口令响应无法读取');
      }
    }
    if (plain.trimLeft().startsWith('{')) {
      try {
        final result = jsonDecode(plain);
        require(result is Map, '移动口令响应格式无效');
        return asJson(result);
      } on FormatException {
        throw const AppException('移动口令响应格式无效');
      }
    }
    require(
      !RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(plain),
      '移动口令响应格式无效',
    );
    XmlDocument document;
    try {
      document = XmlDocument.parse(plain);
    } catch (_) {
      throw const AppException('移动口令响应格式无效');
    }
    final root = document.rootElement;
    Object value(XmlElement element) {
      final children = element.childElements;
      if (children.isEmpty) return element.innerText;
      final result = <String, dynamic>{};
      for (final child in children) {
        final name = child.name.local, item = value(child);
        if (!result.containsKey(name)) {
          result[name] = item;
        } else if (result[name] is List) {
          (result[name] as List).add(item);
        } else {
          result[name] = [result[name], item];
        }
      }
      return result;
    }

    final data = document.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'getOutLinkInfoRes')
        .firstOrNull;
    final code = root.getAttribute('resultCode') ?? '';
    return {
      'resultCode': code,
      'desc': root.getAttribute('desc') ?? '',
      'data': data == null ? {} : value(data),
    };
  }

  static List<Json> items(Json data, String container, String name) {
    final raw = data[container];
    if (raw is List) return raw.map(asJson).toList();
    final nested = asJson(raw)[name];
    if (nested is List) return nested.map(asJson).toList();
    return nested is Map ? [asJson(nested)] : [];
  }
}

class _BoundedResponseSink implements Sink<List<int>> {
  _BoundedResponseSink(this.limit);
  final int limit;
  final _builder = BytesBuilder(copy: false);
  Uint8List get bytes => _builder.takeBytes();
  @override
  void add(List<int> chunk) {
    require(_builder.length + chunk.length <= limit, '移动口令响应过大');
    _builder.add(chunk);
  }

  @override
  void close() {}
}
