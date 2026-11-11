import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../providers/token_session.dart';

part 's3_upload.dart';

class UploadIO {
  UploadIO(this.http, this.file, this.onProgress, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final JsonHttp http;
  final UploadFile file;
  final UploadProgressCallback? onProgress;
  final DateTime Function() clock;
  final Map<(Hash, int, int), String> _hashes = {};

  void progress(UploadPhase phase, [int bytes = 0]) {
    RequestScope.checkpoint();
    onProgress?.call(
      UploadProgress(phase, bytes.clamp(0, file.size), file.size),
    );
  }

  Future<String> digest(Hash algorithm, {int start = 0, int? end}) async {
    final stop = end ?? file.size;
    if (start == 0 && stop == file.size) {
      final name = algorithm == md5
          ? 'md5'
          : algorithm == sha1
          ? 'sha1'
          : algorithm == sha256
          ? 'sha256'
          : null;
      final known = file.verifiedHashes[name];
      if (known != null) {
        await file.validate?.call();
        RequestScope.checkpoint();
        return known;
      }
    }
    final key = (algorithm, start, stop);
    if (_hashes.containsKey(key)) return _hashes[key]!;
    var count = 0;
    final stream = file.openRead(start, stop).map((chunk) {
      RequestScope.checkpoint();
      count += chunk.length;
      progress(UploadPhase.preparing, count);
      return chunk;
    });
    return _hashes[key] = (await algorithm.bind(stream).first).toString();
  }

  Future<Uint8List> bytes(int start, int end) async {
    require(end - start <= 16 * 1024 * 1024, '上传读取缓冲区过大');
    final result = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(start, end)) {
      RequestScope.checkpoint();
      result.add(chunk);
    }
    return result.takeBytes();
  }

  Future<HttpResult> send(
    String url, {
    String method = 'PUT',
    int start = 0,
    int? end,
    Map<String, String> headers = const {},
    Map<String, String>? fields,
    String fieldName = 'file',
    bool retry = true,
    bool includeContentType = true,
    String? contentType,
  }) async {
    checkedCloudUrl(url, '网盘返回的上传地址无效');
    final stop = end ?? file.size;
    for (var attempt = 0; ; attempt++) {
      RequestScope.checkpoint();
      try {
        final result = await http.request(
          method,
          url,
          body: HttpUpload(
            open: () => file.openRead(start, stop).map((chunk) {
              RequestScope.checkpoint();
              return chunk;
            }),
            length: stop - start,
            fields: fields,
            fileName: file.name,
            fieldName: fieldName,
            onProgress: (sent, total) => progress(
              UploadPhase.uploading,
              start + (total > 0 ? ((stop - start) * sent ~/ total) : 0),
            ),
          ),
          headers: headers,
          contentType: includeContentType ? contentType ?? file.mimeType : null,
          followRedirects: false,
        );
        require(result.successful, '文件上传失败（HTTP ${result.status}）');
        progress(UploadPhase.uploading, stop);
        return result;
      } on HttpRequestFailure catch (error) {
        if (!retry ||
            (method != 'PUT' && !error.requestNotSent) ||
            attempt >= 2 ||
            !error.retryable) {
          rethrow;
        }
        await RequestScope.wait(Duration(seconds: attempt + 1));
      }
    }
  }

  Future<CloudFile> confirm(
    Future<List<CloudFile>> Function() list, {
    String id = '',
    bool exactSize = true,
  }) async {
    progress(UploadPhase.finishing, file.size);
    for (var attempt = 0; attempt < 8; attempt++) {
      RequestScope.checkpoint();
      final matches = (await list())
          .where(
            (f) =>
                !f.isDirectory &&
                (id.isNotEmpty ? f.id == id : f.name == file.name),
          )
          .toList();
      require(matches.length <= 1, '上传目录中出现同名文件，请刷新后确认');
      if (matches.isNotEmpty) {
        final result = matches.single;
        require(!exactSize || result.size == file.size, '上传后的文件大小不一致，请重新检查');
        return result;
      }
      await RequestScope.wait(const Duration(milliseconds: 750));
    }
    throw const AppException('上传已提交，网盘仍在处理，请稍后刷新文件列表');
  }

  static String xml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  static bool xmlError(String body) =>
      RegExp(r'<(?:[\w-]+:)?Error(?:\s|>)').hasMatch(body);
  static String xmlValue(String text, String tag) {
    final value =
        RegExp('<$tag>([\\s\\S]*?)</$tag>').firstMatch(text)?.group(1) ?? '';
    return value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  static String completeXml(List<String> etags) =>
      '<CompleteMultipartUpload>${[for (var i = 0; i < etags.length; i++) '<Part><PartNumber>${i + 1}</PartNumber><ETag>${xml(etags[i])}</ETag></Part>'].join()}</CompleteMultipartUpload>';

  /// OSS temporary credentials authorize only the provider's upload object.
  Future<void> oss({
    required String endpoint,
    required String bucket,
    required String object,
    required String access,
    required String secret,
    String token = '',
    bool exactEndpoint = false,
    String? contentType,
    bool abortOnCancel = false,
  }) async {
    require(
      [endpoint, bucket, object, access, secret].every((s) => s.isNotEmpty),
      '网盘未返回完整上传凭据',
    );
    var base = Uri.parse(
      endpoint.contains('://') ? endpoint : 'https://$endpoint',
    );
    if (!exactEndpoint && !base.host.startsWith('$bucket.')) {
      base = base.replace(host: '$bucket.${base.host}');
    }
    final uri = base.replace(
      pathSegments: object.split('/'),
      query: null,
      fragment: null,
    );
    checkedCloudUrl(uri.toString(), '网盘返回的上传地址无效');
    Future<HttpResult> request(
      String method,
      Map<String, String> parameters, {
      String body = '',
      int? start,
      int? end,
    }) async {
      final date = HttpDate.format(clock().toUtc());
      final type =
          contentType ?? (start == null ? 'application/xml' : file.mimeType);
      final canonical = (parameters.keys.toList()..sort())
          .map(
            (key) => parameters[key]!.isEmpty ? key : '$key=${parameters[key]}',
          )
          .join('&');
      final resource =
          '/$bucket/$object${canonical.isEmpty ? '' : '?$canonical'}';
      final signed =
          '$method\n\n$type\n$date\n${token.isEmpty ? '' : 'x-oss-security-token:$token\n'}$resource';
      final signature = base64Encode(
        Hmac(sha1, utf8.encode(secret)).convert(utf8.encode(signed)).bytes,
      );
      final headers = {
        'Authorization': 'OSS $access:$signature',
        'Date': date,
        'Content-Type': type,
        if (token.isNotEmpty) 'x-oss-security-token': token,
      };
      final address = parameters.isEmpty
          ? uri.toString()
          : query(uri.toString(), parameters);
      if (start != null) {
        return send(
          address,
          start: start,
          end: end,
          headers: headers,
          contentType: type,
        );
      }
      final result = await http.request(
        method,
        address,
        body: body,
        headers: headers,
        contentType: type,
        followRedirects: false,
      );
      require(
        result.successful && !xmlError(result.body),
        '网盘上传服务返回错误（HTTP ${result.status}）',
      );
      return result;
    }

    if (file.size == 0) {
      await request('PUT', {}, start: 0, end: 0);
      return;
    }
    final initiated = await request('POST', {'uploads': ''});
    final uploadId = xmlValue(initiated.body, 'UploadId');
    require(uploadId.isNotEmpty, '网盘未创建分段上传任务');
    var complete = false;
    try {
      final size = math.max(8 * 1024 * 1024, (file.size / 9000).ceil());
      final etags = <String>[];
      for (var start = 0; start < file.size; start += size) {
        final result = await request(
          'PUT',
          {'partNumber': '${etags.length + 1}', 'uploadId': uploadId},
          start: start,
          end: math.min(file.size, start + size),
        );
        final etag = result.header('etag');
        require(etag.isNotEmpty, '网盘未确认上传分段');
        etags.add(etag);
      }
      progress(UploadPhase.finishing, file.size);
      final result = await request('POST', {
        'uploadId': uploadId,
      }, body: completeXml(etags));
      require(!result.body.contains('<Error>'), '网盘未完成分段合并');
      complete = true;
    } finally {
      if (!complete &&
          (abortOnCancel || RequestScope.current?.isCancelled != true)) {
        try {
          await RequestScope().run(
            () => request('DELETE', {'uploadId': uploadId}),
          );
        } catch (_) {}
      }
    }
  }
}
