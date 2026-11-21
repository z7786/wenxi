import 'dart:async';
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
import 'upload_concurrency.dart';
import 'upload_hash.dart';

part 's3_upload.dart';

/// Keep rejected payload responses available to provider-specific recovery.
/// The exception message exposes only a bounded error code, never a signed
/// request, storage object name, or the upstream's unfiltered response body.
class UploadResponseFailure extends AppException {
  UploadResponseFailure(this.response)
    : code = _code(response),
      super(
        '文件上传失败（HTTP ${response.status}${_code(response).isEmpty ? '' : '，${_code(response)}'}）',
      );

  final HttpResult response;
  final String code;

  static String _code(HttpResult response) {
    final body = response.body.length > 16384
        ? response.body.substring(0, 16384)
        : response.body;
    var value = UploadIO.xmlValue(body, 'Code').trim();
    if (value.isEmpty && body.trimLeft().startsWith('{')) {
      try {
        final json = asJson(jsonDecode(body));
        value = json.str('code').ifEmpty(json.str('Code')).trim();
      } on FormatException {
        // HTML errors and truncated responses do not contain a usable code.
      }
    }
    return RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,79}$').hasMatch(value)
        ? value
        : '';
  }
}

class UploadIO {
  UploadIO(this.http, this.file, this.onProgress, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final JsonHttp http;
  final UploadFile file;
  final UploadProgressCallback? onProgress;
  final DateTime Function() clock;
  final Map<(Hash, int, int), String> _hashes = {};
  final Map<(int, int), int> _sentParts = {};
  int _sent = 0, _lastSent = 0;
  bool _sendingParts = false;

  static String? _hashName(Hash algorithm) => algorithm == md5
      ? 'md5'
      : algorithm == sha1
      ? 'sha1'
      : algorithm == sha256
      ? 'sha256'
      : null;

  static Hash _hashAlgorithm(String name) => switch (name) {
    'md5' => md5,
    'sha1' => sha1,
    'sha256' => sha256,
    _ => throw const AppException('文件校验算法不支持'),
  };

  String? _knownHash(Hash algorithm, int start, int end) =>
      _hashes[(algorithm, start, end)] ??
      (start == 0 && end == file.size
          ? file.verifiedHashes[_hashName(algorithm)]
          : null);

  void notSavedYet() => WriteRequestScope.current?.notSavedYet();

  Future<T> temporary<T>(Future<T> Function() action) =>
      WriteRequestScope.current?.payload(false, action) ?? action();

  void progress(UploadPhase phase, [int bytes = 0]) {
    RequestScope.checkpoint();
    // A worker may still be hashing a signed part while another is uploading.
    // It must not reset the visible phase or report an absolute file offset.
    if (_sendingParts && phase == UploadPhase.preparing) return;
    onProgress?.call(
      UploadProgress(phase, bytes.clamp(0, file.size), file.size),
    );
  }

  /// Only providers with independent temporary parts opt into this scheduler.
  /// Each failed run cancels siblings, waits for them, and never reaches merge.
  Future<void> parts(
    int count,
    Future<void> Function(int index) upload, {
    int concurrent = 3,
  }) async {
    require(count >= 0 && !_sendingParts, '上传分段任务无效');
    RequestScope.checkpoint();
    if (count == 0) return;
    final parent = RequestScope.current, scope = RequestScope();
    var finished = false, next = 0;
    Object? failure;
    StackTrace? failureStack;
    unawaited(
      parent?.whenCancel.then((_) {
        if (!finished) scope.cancel();
      }),
    );
    _sendingParts = true;
    Future<void> worker() async {
      try {
        while (next < count) {
          RequestScope.checkpoint();
          final index = next++;
          await uploadConnections.run(() => upload(index));
        }
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
        scope.cancel();
      }
    }

    try {
      await scope.run(
        () => RequestScope.guarded(
          () => Future.wait([
            for (var i = 0; i < math.min(count, concurrent.clamp(1, 4)); i++)
              worker(),
          ]),
          () => require(parent?.isCancelled != true, '请求已取消'),
        ),
      );
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      RequestScope.checkpoint();
    } finally {
      finished = true;
      _sendingParts = false;
    }
  }

  void _partProgress(int start, int end, int bytes) {
    final key = (start, end), previous = _sentParts[(start, end)] ?? 0;
    final value = bytes.clamp(0, end - start);
    _sentParts[key] = value;
    _sent += value - previous;
    // Retries replace this part's byte count instead of adding duplicate bytes.
    // Keep displayed progress monotonic while the same part is retransmitted.
    _lastSent = math.max(_lastSent, _sent);
    progress(UploadPhase.uploading, _lastSent);
  }

  /// Precreate may acknowledge existing blocks. They contribute to completion
  /// but are seeded before uploading begins so they are not counted as traffic.
  void reusePart(int start, int end) {
    require(
      !_sendingParts && start >= 0 && end >= start && end <= file.size,
      '上传分段范围无效',
    );
    final previous = _sentParts[(start, end)] ?? 0;
    _sentParts[(start, end)] = end - start;
    _sent += end - start - previous;
    _lastSent = math.max(_lastSent, _sent);
  }

  Future<String> digest(Hash algorithm, {int start = 0, int? end}) async {
    final stop = end ?? file.size;
    if (start == 0 && stop == file.size) {
      final name = _hashName(algorithm);
      final known = file.verifiedHashes[name];
      if (known != null) {
        await file.validate?.call();
        RequestScope.checkpoint();
        return known;
      }
    }
    final key = (algorithm, start, stop);
    if (_hashes.containsKey(key)) return _hashes[key]!;
    if (_hashName(algorithm) case final name?) {
      final result = await hashUploadStream(
        file.openRead(start, stop),
        UploadHashPlan(size: stop - start, whole: [name]),
        onProgress: (count) => progress(UploadPhase.preparing, count),
      );
      return _hashes[key] = result.whole[name]!;
    }
    var count = 0;
    final stream = file.openRead(start, stop).map((chunk) {
      RequestScope.checkpoint();
      count += chunk.length;
      progress(UploadPhase.preparing, count);
      return chunk;
    });
    return _hashes[key] = (await algorithm.bind(stream).first).toString();
  }

  /// Compute all provider-required hashes in one read, retaining verified relay
  /// digests and caching the individual ranges for subsequent signing/retries.
  Future<UploadHashResult> hashes({
    List<String> whole = const [],
    String? partAlgorithm,
    int partSize = 0,
    String? prefixAlgorithm,
    int prefixSize = 0,
  }) async {
    RequestScope.checkpoint();
    final plan = UploadHashPlan(
      size: file.size,
      whole: whole,
      partAlgorithm: partAlgorithm,
      partSize: partSize,
      prefixAlgorithm: prefixAlgorithm,
      prefixSize: prefixSize,
    );
    final values = <String, String>{};
    for (final name in whole.toSet()) {
      final known = _knownHash(_hashAlgorithm(name), 0, file.size);
      if (known != null) values[name] = known;
    }
    final count = partAlgorithm == null
        ? 0
        : math.max(1, (file.size / partSize).ceil());
    final parts = <String>[];
    if (partAlgorithm != null) {
      for (var i = 0; i < count; i++) {
        final known = _knownHash(
          _hashAlgorithm(partAlgorithm),
          i * partSize,
          math.min(file.size, (i + 1) * partSize),
        );
        if (known == null) break;
        parts.add(known);
      }
    }
    final prefix = prefixAlgorithm == null
        ? null
        : _knownHash(
            _hashAlgorithm(prefixAlgorithm),
            0,
            math.min(file.size, prefixSize),
          );
    final missingWhole = whole.toSet().difference(values.keys.toSet()).toList();
    final missingParts = parts.length < count;
    final missingPrefix = prefixAlgorithm != null && prefix == null;
    if (missingWhole.isEmpty && !missingParts && !missingPrefix) {
      await file.validate?.call();
      RequestScope.checkpoint();
      return UploadHashResult(values, parts, prefix);
    }
    final result = await hashUploadStream(
      file.openRead(),
      UploadHashPlan(
        size: plan.size,
        whole: missingWhole,
        partAlgorithm: missingParts ? partAlgorithm : null,
        partSize: partSize,
        prefixAlgorithm: missingPrefix ? prefixAlgorithm : null,
        prefixSize: prefixSize,
      ),
      onProgress: (count) => progress(UploadPhase.preparing, count),
    );
    for (final entry in result.whole.entries) {
      _hashes[(_hashAlgorithm(entry.key), 0, file.size)] = entry.value;
    }
    if (missingParts) {
      for (var i = 0; i < result.parts.length; i++) {
        _hashes[(
              _hashAlgorithm(partAlgorithm!),
              i * partSize,
              math.min(file.size, (i + 1) * partSize),
            )] =
            result.parts[i];
      }
    }
    if (missingPrefix) {
      _hashes[(
            _hashAlgorithm(prefixAlgorithm),
            0,
            math.min(file.size, prefixSize),
          )] =
          result.prefix!;
    }
    return UploadHashResult(
      {...values, ...result.whole},
      missingParts ? result.parts : parts,
      missingPrefix ? result.prefix : prefix,
    );
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
    bool commitsFile = true,
    bool includeContentType = true,
    String? contentType,
  }) async {
    require(!_sendingParts || !commitsFile, '独立分片不能提前合并文件');
    checkedCloudUrl(url, '网盘返回的上传地址无效');
    final stop = end ?? file.size;
    if (!_sendingParts) notSavedYet();
    Future<HttpResult> upload() async {
      for (var attempt = 0; ; attempt++) {
        RequestScope.checkpoint();
        try {
          _partProgress(start, stop, 0);
          Future<HttpResult> send() => http.request(
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
              onProgress: (sent, total) => _partProgress(
                start,
                stop,
                total > 0 ? ((stop - start) * sent ~/ total) : 0,
              ),
            ),
            headers: headers,
            contentType: includeContentType
                ? contentType ?? file.mimeType
                : null,
            followRedirects: false,
          );
          final attempt = WriteRequestScope.current;
          final result = attempt == null
              ? await send()
              : await attempt.payload(commitsFile && stop == file.size, send);
          if (!result.successful) throw UploadResponseFailure(result);
          _partProgress(start, stop, stop - start);
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

    return _sendingParts ? upload() : uploadConnections.run(upload);
  }

  Future<CloudFile> confirm(
    Future<List<CloudFile>> Function() list, {
    String id = '',
    bool exactSize = true,
    CloudFile? receipt,
  }) async {
    await WriteRequestScope.current?.acceptedId(id.ifEmpty(receipt?.id ?? ''));
    progress(UploadPhase.finishing, file.size);
    // Only a provider's completed/rapid-save response qualifies. Missing
    // metadata still uses directory confirmation; a mismatched receipt fails.
    if (receipt != null) {
      final name = receipt.name;
      require(
        receipt.id.isNotEmpty &&
            (id.isEmpty || receipt.id == id) &&
            !receipt.isDirectory &&
            name == file.name,
        '上传回执与文件信息不一致，请刷新目录确认',
      );
      require(!exactSize || receipt.size == file.size, '上传后的文件大小不一致，请重新检查');
      if (receipt.hashType case final algorithm?) {
        if (const {'md5', 'sha1', 'sha256'}.contains(algorithm)) {
          final expected = _knownHash(_hashAlgorithm(algorithm), 0, file.size);
          require(
            expected == null ||
                receipt.hashValue?.toLowerCase() == expected.toLowerCase(),
            '上传后的文件校验标识不一致，请重新检查',
          );
        }
      }
      return receipt;
    }
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
          commitsFile: !parameters.containsKey('uploadId'),
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
    final initiated = await temporary(() => request('POST', {'uploads': ''}));
    final uploadId = xmlValue(initiated.body, 'UploadId');
    require(uploadId.isNotEmpty, '网盘未创建分段上传任务');
    var complete = false;
    try {
      notSavedYet();
      final size = math.max(8 * 1024 * 1024, (file.size / 9000).ceil());
      final count = (file.size / size).ceil();
      final etags = List.filled(count, '');
      await parts(count, (index) async {
        final start = index * size;
        final result = await request(
          'PUT',
          {'partNumber': '${index + 1}', 'uploadId': uploadId},
          start: start,
          end: math.min(file.size, start + size),
        );
        final etag = result.header('etag');
        require(etag.isNotEmpty, '网盘未确认上传分段');
        etags[index] = etag;
      });
      notSavedYet();
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
            () => temporary(() => request('DELETE', {'uploadId': uploadId})),
          );
        } catch (_) {}
      }
    }
  }
}
