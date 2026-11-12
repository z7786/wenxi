import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/json.dart';
import '../data/http.dart';
import '../diagnostics/app_log.dart';
import '../domain/baidu_share_route.dart';
import '../domain/downloads.dart';
import '../domain/github_acceleration.dart';
import '../domain/models.dart';
import '../domain/settings.dart';
import '../download/transfer_http.dart';
import '../download/native_http_probe.dart';
import '../platform/native_engine.dart';

/// Uses the same range engine and per-provider policy as ordinary downloads.
/// Checkpoints contain file identity and options, never signed URLs or headers.
class CrossTransferDownload {
  const CrossTransferDownload({
    required this.engine,
    required this.http,
    required this.settings,
    required this.checkSpace,
  });

  final GopeedEngine engine;
  final TransferHttp http;
  final AppSettings Function() settings;
  final Future<void> Function(int remaining) checkSpace;

  Future<DownloadSpec> download({
    required String id,
    required String sourceKey,
    required DownloadSpec spec,
    required File payload,
    required File checkpoint,
    required int expectedSize,
    required void Function(int received, int total) onProgress,
    required Future<DownloadSpec> Function(DownloadSpec) refresh,
  }) async {
    var options = settings();
    Json saved = {};
    if (await checkpoint.exists()) {
      try {
        require(
          await FileSystemEntity.type(checkpoint.path, followLinks: false) ==
              FileSystemEntityType.file,
          '中转缓存位置发生变化',
        );
        saved = asJson(jsonDecode(await checkpoint.readAsString()));
        require(
          saved.integer('version') == 1 && saved.str('source') == sourceKey,
          '中转文件来源已变化',
        );
      } catch (_) {
        RequestScope.checkpoint();
        saved = {};
      }
    }
    final previousOptions = saved.obj('options');
    if (previousOptions.isNotEmpty) {
      // Like a normal download task, a checkpoint keeps its captured options.
      options = AppSettings.fromJson({...options.toJson(), ...previousOptions});
    }
    var identity = saved['identity'] is Map
        ? RemoteIdentity.fromJson(saved.obj('identity'))
        : const RemoteIdentity(0, null, null);
    final nativePayload = File(
      p.join(engine.taskDirectory(id).path, 'payload.gopeed'),
    );
    var started = false;
    try {
      for (var attempt = 0; ; attempt++) {
        RequestScope.checkpoint();
        try {
          final candidates = options.githubAcceleration.downloadCandidates(
            spec,
          );
          late Probe probe;
          var transferSpec = candidates.first;
          for (var route = 0; ; route++) {
            transferSpec = candidates[route];
            try {
              probe =
                  transferSpec.networkPolicy == null &&
                      (spec.profile == 'wopan' ||
                          spec.platform == CloudPlatform.github &&
                              GitHubAcceleration.permits(
                                spec.url,
                                spec.headers,
                              ))
                  ? await NativeHttpProbe(
                      engine,
                    ).probe(transferSpec, id: id, delay: RequestScope.wait)
                  : await http.probeDownload(transferSpec);
              break;
            } catch (error) {
              RequestScope.checkpoint();
              if (route + 1 >= candidates.length ||
                  !(retryableDownloadError(error) ||
                      error is DownloadProbeContentException)) {
                rethrow;
              }
            }
          }
          RequestScope.checkpoint();
          require(
            !probe.hls &&
                !RegExp(
                  r'\.(m3u8|mpd)$',
                  caseSensitive: false,
                ).hasMatch(Uri.parse(spec.url).path),
            '来源返回视频播放列表，无法按原文件跨盘传输',
          );
          require(
            !probe.contentType.contains('text/html') ||
                RegExp(
                  r'\.html?$',
                  caseSensitive: false,
                ).hasMatch(spec.fileName),
            '下载返回登录页面，请重新登录来源网盘',
          );
          final expected = spec.expectedSize > 0
              ? spec.expectedSize
              : expectedSize;
          final total = probe.identity.total;
          require(
            expected <= 0 || total <= 0 || total == expected,
            '下载内容与所选文件大小不一致',
          );
          final present = await FileSystemEntity.type(
            nativePayload.path,
            followLinks: false,
          );
          require(
            present == FileSystemEntityType.file ||
                present == FileSystemEntityType.notFound,
            '中转缓存位置发生变化',
          );
          final resume =
              present == FileSystemEntityType.file &&
              probe.rangeSupported &&
              identity.canResume(probe.identity) &&
              await nativePayload.length() == total;
          if (!resume) {
            await engine.remove(id);
          }
          identity = probe.identity;
          await checkSpace(
            resume ? 0 : (total > 0 ? total : expected).clamp(0, 1 << 60),
          );
          RequestScope.checkpoint();
          final profile = BaiduShareRoute.downloadProfile(spec);
          var connections = options.connectionsFor(spec.platform, profile);
          if (spec.maxPlaybackConnections case final maximum?) {
            connections = connections.clamp(1, maximum.clamp(1, 512));
          }
          await checkpoint.writeAsString(
            jsonEncode({
              'version': 1,
              'source': sourceKey,
              'identity': identity.toJson(),
              'options': {
                'threads': options.threads,
                'downloadThreadOverrides': options.threadOverrides,
                'retries': options.retries,
                'downloadRetryPolicy': 1,
                'speedLimit': options.speedLimit,
              },
            }),
            flush: true,
          );
          DiagnosticLog.event(
            'cross_transfer.download_start',
            fields: {
              'ref': DiagnosticLog.reference(id),
              'platform': spec.platform?.key,
              'profile': profile,
              'connections': connections,
              'retries': options.retries,
              'speedLimit': options.speedLimit,
              'resuming': resume,
            },
          );
          started = true;
          final account = asJson(
            spec.source?['session'],
          ).obj('metadata').str('accountId');
          await engine.begin({
            'id': id,
            'url': transferSpec.url,
            'headers': {
              ...http.headers(spec.headers),
              if (identity.ifRange != null) 'If-Range': identity.ifRange!,
            },
            if (spec.networkPolicy != null)
              'networkPolicy': spec.networkPolicy!.toJson(),
            'connections': connections,
            'connectionProfile': options.connectionProfileFor(
              spec.platform,
              profile,
            ),
            'retries': options.retries,
            'speedLimit': options.speedLimit,
            if (spec.platform == CloudPlatform.aliyun && account.isNotEmpty)
              'aliyunGroup': sha256
                  .convert(utf8.encode('aliyun:$account'))
                  .toString(),
          });
          var checkedAt = DateTime.now();
          while (true) {
            RequestScope.checkpoint();
            final state = await engine.snapshot(id);
            RequestScope.checkpoint();
            final nativeTotal = state.integer('total');
            require(
              total <= 0 || nativeTotal <= 0 || nativeTotal == total,
              '下载内容与所选文件大小不一致',
            );
            final currentTotal = nativeTotal > 0
                ? nativeTotal
                : total > 0
                ? total
                : expected;
            final received = state.integer('downloaded');
            onProgress(received, currentTotal);
            if (DateTime.now().difference(checkedAt).inSeconds >= 2) {
              await checkSpace((currentTotal - received).clamp(0, 1 << 60));
              checkedAt = DateTime.now();
            }
            final status = state.str('status');
            if (status == 'done') {
              // Use the app's native cache on every platform. Android's direct
              // output leases are reserved for user-selected documents.
              await engine.pause(id);
              RequestScope.checkpoint();
              require(
                p.equals(
                  p.normalize(state.str('path')),
                  p.normalize(nativePayload.absolute.path),
                ),
                '中转下载路径发生变化',
              );
              require(
                await FileSystemEntity.type(
                      nativePayload.path,
                      followLinks: false,
                    ) ==
                    FileSystemEntityType.file,
                '中转缓存位置发生变化',
              );
              final size = await nativePayload.length();
              require(
                (currentTotal <= 0 || size == currentTotal) &&
                    (expected <= 0 || size == expected) &&
                    (size > 0 || expectedSize == 0),
                '中转下载结果不完整',
              );
              await engine.remove(id);
              // Both directories are in the app cache: rename avoids a second
              // full-file copy while separating upload retries from the engine.
              await nativePayload.rename(payload.absolute.path);
              onProgress(size, size);
              return spec;
            }
            if (status == 'error') {
              final code = state.integer('httpCode');
              if (code > 0) {
                throw DownloadHttpException(
                  code,
                  retryAfter: Duration(
                    milliseconds: state.integer('retryAfterMs'),
                  ),
                  exhausted: state.boolean('retryExhausted', true),
                );
              }
              if (state.str('errorKind') == 'network') {
                throw DownloadNetworkException(
                  'native',
                  retryable: !state.boolean('retryExhausted', true),
                );
              }
              throw AppException(state.str('error').ifEmpty('跨盘下载失败，请继续任务'));
            }
            require(status != 'pause', '跨盘下载已暂停，请继续任务');
            await RequestScope.wait(const Duration(milliseconds: 350));
          }
        } catch (error) {
          RequestScope.checkpoint();
          if (started) await engine.pause(id);
          final expired = error is DownloadHttpException && error.mayRefresh;
          if (!expired && !retryableDownloadError(error)) rethrow;
          if (attempt >= options.retries) throw DownloadRetryExhausted(error);
          final delay = downloadRetryDelay(attempt, error);
          DiagnosticLog.event(
            'cross_transfer.download_retry',
            fields: {
              'ref': DiagnosticLog.reference(id),
              'attempt': attempt + 1,
              'waitMs': delay.inMilliseconds,
              'status': error is DownloadHttpException ? error.status : 0,
            },
          );
          await RequestScope.wait(delay);
          if (expired) spec = await refresh(spec);
        }
      }
    } finally {
      if (started) await engine.pause(id);
    }
  }
}
