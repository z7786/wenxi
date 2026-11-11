import 'dart:async';
import 'dart:convert';
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

/// Verified payloads survive upload failures; no URLs or credentials are saved.
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
  Iterable<String>? _retainedTaskIds;

  void retainTasks(Iterable<String> ids) => _retainedTaskIds = List.of(ids);

  Future<void> initialize({Iterable<String>? retainedTaskIds}) =>
      _initialization ??= _initialize(retainedTaskIds ?? _retainedTaskIds);

  String _key(String value) => sha256.convert(utf8.encode(value)).toString();
  Directory _taskDirectory(String id) =>
      Directory(p.join(cache.path, 'relay-${_key(id)}'));
  Directory _entryDirectory(String taskId, String entryId) =>
      Directory(p.join(_taskDirectory(taskId).path, _key(entryId)));

  Future<void> _delete(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    require(
      await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.directory,
      '中转缓存位置发生变化',
    );
    final root = await cache.resolveSymbolicLinks();
    final target = await directory.resolveSymbolicLinks();
    require(p.isWithin(root, target), '中转缓存位置无效');
    await directory.delete(recursive: true);
  }

  Future<void> clearTask(String taskId) => _delete(_taskDirectory(taskId));
  Future<void> clearEntry(String taskId, String entryId) async {
    await _delete(_entryDirectory(taskId, entryId));
    final directory = _taskDirectory(taskId);
    if (await directory.exists() && await directory.list().isEmpty) {
      await _delete(directory);
    }
  }

  Future<void> _initialize(Iterable<String>? retainedTaskIds) async {
    if (!await cache.exists()) return;
    final retained = retainedTaskIds?.map((id) => 'relay-${_key(id)}').toSet();
    try {
      await for (final item in cache.list(followLinks: false)) {
        if (item is Directory &&
            p.basename(item.path).startsWith('relay-') &&
            (retained == null || !retained.contains(p.basename(item.path)))) {
          await _delete(item);
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
    required String taskId,
    required String entryId,
    required String? expectedMd5,
    required void Function(int received, int total) onProgress,
    required Future<T> Function(UploadFile file, String md5) upload,
  }) async {
    RequestScope.checkpoint();
    await initialize();
    await cache.create(recursive: true);
    final directory = _entryDirectory(taskId, entryId);
    await directory.create(recursive: true);
    final payload = File(p.join(directory.path, 'payload'));
    final metadata = File(p.join(directory.path, 'verified.json'));
    DownloadSpec? spec;
    var digest = '', sha1Digest = '';
    var ready = false, uploaded = false;
    try {
      if (await metadata.exists() && await payload.exists()) {
        try {
          final saved = asJson(jsonDecode(await metadata.readAsString()));
          require(
            await FileSystemEntity.type(payload.path, followLinks: false) ==
                    FileSystemEntityType.file &&
                await FileSystemEntity.type(
                      metadata.path,
                      followLinks: false,
                    ) ==
                    FileSystemEntityType.file,
            '中转缓存位置发生变化',
          );
          final length = await payload.length();
          require(
            saved.integer('size', -1) == length && length >= 0,
            '中转缓存大小不一致',
          );
          final md5Result = _DigestSink(), sha1Result = _DigestSink();
          final md5Input = md5.startChunkedConversion(md5Result),
              sha1Input = sha1.startChunkedConversion(sha1Result);
          await for (final bytes in payload.openRead()) {
            RequestScope.checkpoint();
            md5Input.add(bytes);
            sha1Input.add(bytes);
          }
          md5Input.close();
          sha1Input.close();
          digest = md5Result.value.toString();
          sha1Digest = sha1Result.value.toString();
          require(
            saved.str('md5') == digest &&
                saved.str('sha1') == sha1Digest &&
                (contentMd5(expectedMd5) == null ||
                    contentMd5(expectedMd5) == digest),
            '中转缓存校验失败',
          );
          ready = true;
          onProgress(length, length);
        } catch (_) {
          RequestScope.checkpoint();
          await metadata.delete();
        }
      }
      for (var attempt = 0; !ready; attempt++) {
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
          final sha1Result = _DigestSink();
          final sha1Input = sha1.startChunkedConversion(sha1Result);
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
            sha1Input.add(chunk);
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
          sha1Input.close();
          otherInput?.close();
          digest = md5Result.value!.toString();
          sha1Digest = sha1Result.value!.toString();
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
          await metadata.writeAsString(
            jsonEncode({'size': received, 'md5': digest, 'sha1': sha1Digest}),
            flush: true,
          );
          ready = true;
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
      final result = await upload(
        UploadFile(
          name: file.name,
          size: size,
          read: (start, end) => payload.openRead(start, end),
          verifiedHashes: {'md5': digest, 'sha1': sha1Digest},
        ),
        digest,
      );
      uploaded = true;
      return result;
    } finally {
      // Cleanup must run even inside a cancelled account/request scope.
      try {
        await RequestScope().run(() async {
          await cloud.cleanups.release(spec?.cleanup);
          await cloud.cleanups.ready(spec?.cleanup);
        }, inheritGuard: false);
      } finally {
        try {
          if (!ready || uploaded) await clearEntry(taskId, entryId);
        } catch (e, s) {
          DiagnosticLog.error('cross_transfer.cache_cleanup', e, s);
        }
      }
    }
  }
}
