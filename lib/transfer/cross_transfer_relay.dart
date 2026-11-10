import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../data/cloud_repository.dart';
import '../data/http.dart';
import '../diagnostics/app_log.dart';
import '../domain/models.dart';
import '../domain/rapid_transfer.dart';
import '../domain/uploads.dart';
import '../download/space_budget.dart';
import '../download/transfer_http.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// One file on disk at a time. Download URLs and temporary paths are never saved.
class CrossTransferRelay {
  CrossTransferRelay({
    required this.cloud,
    required this.http,
    required this.cache,
    this.availableSpace,
  });
  final CloudRepository cloud;
  final TransferHttp http;
  final Directory cache;
  final Future<int> Function(String path)? availableSpace;
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!await cache.exists()) return;
    // This directory belongs only to the cross-cloud queue.
    try {
      await for (final item in cache.list(followLinks: false)) {
        if (p.basename(item.path).startsWith('relay-')) {
          await item.delete(recursive: item is Directory);
        }
      }
    } catch (e, s) {
      DiagnosticLog.error('cross_transfer.cache_restore', e, s);
    }
  }

  Future<void> _space(int remaining) async {
    if (availableSpace == null) return;
    final free = await availableSpace!(cache.path);
    if (free >= 0 && free < remaining + 32 * 1024 * 1024) {
      throw const DownloadSpaceException();
    }
    RequestScope.checkpoint();
  }

  Future<T> transfer<T>(
    BrowseSession source,
    CloudFile file, {
    required String? expectedMd5,
    required void Function(int received, int total) onProgress,
    required Future<T> Function(UploadFile file, String md5) upload,
  }) async {
    RequestScope.checkpoint();
    await initialize();
    await cache.create(recursive: true);
    final directory = await cache.createTemp('relay-');
    final payload = File(p.join(directory.path, 'payload'));
    DownloadSpec? spec;
    var digest = '';
    try {
      for (var attempt = 0; ; attempt++) {
        final cancel = CancelToken();
        final parent = RequestScope.current;
        parent?.whenCancel.then((_) => cancel.cancel());
        if (parent?.isCancelled == true) cancel.cancel();
        RandomAccessFile? writer;
        try {
          RequestScope.checkpoint();
          spec ??= await cloud.prepareTransfer(source, file);
          RequestScope.checkpoint();
          final response = await http.streamDownload(spec, cancel: cancel);
          if (response.statusCode != 200) {
            throw DownloadHttpException.response(response);
          }
          final type =
              response.headers.value('content-type')?.toLowerCase() ?? '';
          require(
            !type.contains('mpegurl') &&
                !Uri.parse(spec.url).path.toLowerCase().endsWith('.m3u8'),
            '来源返回视频播放列表，无法按原文件跨盘传输',
          );
          require(
            !type.contains('text/html') ||
                RegExp(r'\.html?$', caseSensitive: false).hasMatch(file.name),
            '下载返回登录页面，请重新登录来源网盘',
          );
          final expected = spec.expectedSize > 0
              ? spec.expectedSize
              : source.platform.exactFileSize
              ? file.size
              : 0;
          final length = int.tryParse(
            response.headers.value('content-length') ?? '',
          );
          require(length == null || length >= 0, '下载文件大小无效');
          require(
            expected <= 0 || length == null || length == expected,
            '下载内容与所选文件大小不一致',
          );
          final total = length ?? expected;
          await _space(total);
          writer = await payload.open(mode: FileMode.write);
          final md5Result = _DigestSink();
          final md5Input = md5.startChunkedConversion(md5Result);
          final algorithm = spec.checksumType?.toLowerCase().replaceAll(
            '-',
            '',
          );
          final otherHash = switch (algorithm) {
            'sha1' => sha1,
            'sha256' => sha256,
            _ => null,
          };
          final otherResult = _DigestSink();
          final otherInput = otherHash?.startChunkedConversion(otherResult);
          var received = 0, checked = 0;
          onProgress(0, total);
          await for (final chunk in response.data!.stream.timeout(
            const Duration(seconds: 45),
          )) {
            RequestScope.checkpoint();
            received += chunk.length;
            require(total <= 0 || received <= total, '下载内容超过预期大小');
            await writer.writeFrom(chunk);
            md5Input.add(chunk);
            otherInput?.add(chunk);
            onProgress(received, total);
            if (received - checked >= 32 * 1024 * 1024) {
              await _space((total - received).clamp(0, total));
              checked = received;
            }
          }
          await writer.close();
          writer = null;
          cancel.cancel();
          RequestScope.checkpoint();
          if (total > 0 && received != total) {
            throw const DownloadNetworkException('incomplete');
          }
          require(received > 0 || file.size == 0, '下载返回空文件');
          md5Input.close();
          otherInput?.close();
          digest = md5Result.value!.toString();
          final trusted =
              contentMd5(expectedMd5) ??
              (algorithm == 'md5' ? contentMd5(spec.checksumValue) : null);
          require(trusted == null || trusted == digest, '文件校验失败，请重新传输');
          require(
            otherHash == null ||
                spec.checksumValue?.isNotEmpty != true ||
                otherResult.value.toString() ==
                    spec.checksumValue!.toLowerCase(),
            '文件校验失败，请重新传输',
          );
          onProgress(received, received);
          // Upload is outside the download retry block: an uncertain write must
          // be reconciled with the target before any user retry.
          break;
        } catch (e) {
          RequestScope.checkpoint();
          final refresh = e is DownloadHttpException && e.mayRefresh;
          if (attempt >= 2 || !refresh && !retryableDownloadError(e)) rethrow;
          await RequestScope.wait(downloadRetryDelay(attempt, e));
          if (refresh) {
            final previous = spec!;
            spec = await cloud.refresh(previous);
            await cloud.cleanups.release(previous.cleanup);
            await cloud.cleanups.ready(previous.cleanup);
          }
        } finally {
          cancel.cancel();
          await writer?.close();
        }
      }
      final size = await payload.length();
      RequestScope.checkpoint();
      return await upload(
        UploadFile(
          name: file.name,
          size: size,
          read: (start, end) => payload.openRead(start, end),
        ),
        digest,
      );
    } finally {
      // Cleanup must run even inside a cancelled account/request scope.
      try {
        await RequestScope().run(() async {
          await cloud.cleanups.release(spec?.cleanup);
          await cloud.cleanups.ready(spec?.cleanup);
        }, inheritGuard: false);
      } finally {
        try {
          await directory.delete(recursive: true);
        } catch (e, s) {
          DiagnosticLog.error('cross_transfer.cache_cleanup', e, s);
        }
      }
    }
  }
}
