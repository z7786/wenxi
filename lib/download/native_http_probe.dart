import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/json.dart';
import '../data/http.dart';
import '../domain/models.dart';
import '../platform/native_engine.dart';
import 'transfer_http.dart';

class DownloadProbeContentException extends AppException {
  const DownloadProbeContentException() : super('返回内容过大或文件范围不正确');
}

class NativeHttpProbe {
  const NativeHttpProbe(this.engine);
  final GopeedEngine engine;

  Future<Json> request(
    String url,
    Map<String, String> headers, {
    String? id,
    int? readLimit,
    bool sampleOnly = false,
    bool Function(Uint8List)? validate,
    void Function()? checkpoint,
    Future<void> Function(Duration)? delay,
  }) async {
    final key = id ?? newId();
    void check() {
      RequestScope.checkpoint();
      checkpoint?.call();
    }

    try {
      check();
      await engine.httpProbeCall('httpProbeStart', {
        'id': key,
        'url': url,
        'headers': headers,
        'readLimit': ?readLimit,
        if (sampleOnly) 'sampleOnly': true,
      });
      while (true) {
        check();
        final state = await engine.httpProbeCall('httpProbeStatus', {
          'id': key,
        });
        check();
        final status = state.str('status');
        if (status == 'done') {
          if (readLimit != null && (!sampleOnly || validate != null)) {
            final code = state.integer('code');
            if (code < 200 || code >= 300) {
              throw DownloadHttpException(
                code,
                retryAfter: parseRetryAfter(
                  state.obj('headers').str('retry-after'),
                ),
              );
            }
            final body = base64Decode(state.str('body'));
            require(
              body.isNotEmpty &&
                  body.length <= readLimit &&
                  (validate?.call(body) ?? true),
              '返回内容不是测试文件，可能为错误页面或无效镜像',
            );
          }
          return state;
        }
        if (status == 'error') {
          if (state.str('errorKind') == 'certificate') {
            throw const AppException('服务器证书校验失败');
          }
          if (state.str('errorKind') == 'content') {
            throw const DownloadProbeContentException();
          }
          throw DownloadNetworkException(
            'nativeProbe',
            retryable: state.boolean('retryable'),
          );
        }
        require(status == 'running', '下载连接检查已取消或响应无效');
        await (delay?.call(const Duration(milliseconds: 100)) ??
            Future<void>.delayed(const Duration(milliseconds: 100)));
      }
    } finally {
      await engine.httpProbeCall('httpProbeStop', {'id': key});
    }
  }

  Future<Probe> probe(
    DownloadSpec spec, {
    String? id,
    void Function()? checkpoint,
    Future<void> Function(Duration)? delay,
    int sampleBytes = 0,
  }) async {
    final state = await request(
      spec.url,
      TransferHttp.normalizedHeaders(spec.headers),
      id: id,
      checkpoint: checkpoint,
      delay: delay,
      readLimit: sampleBytes > 0 ? sampleBytes : null,
      sampleOnly: sampleBytes > 0,
    );
    return Probe.response(
      state.integer('code'),
      {
        for (final entry in state.obj('headers').entries)
          if (entry.value is String) entry.key: entry.value as String,
      },
      hlsPath: state.boolean('hlsPath'),
      host: state.str('host'),
      probeBytes: sampleBytes > 0 ? sampleBytes : 1,
    );
  }
}
