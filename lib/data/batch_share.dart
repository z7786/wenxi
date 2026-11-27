import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../domain/models.dart';
import 'http.dart';

class BatchShareEntry {
  const BatchShareEntry(this.file, {this.share, this.error});
  final CloudFile file;
  final ShareCreation? share;
  final String? error;
}

class BatchShareReport {
  const BatchShareReport(
    this.total,
    this.entries, {
    this.finished = false,
    this.reason,
  });
  final int total;
  final List<BatchShareEntry> entries;
  final bool finished;
  final String? reason;
  int get succeeded => entries.where((entry) => entry.share != null).length;
  int get failed => entries.length - succeeded;
  String get text => entries
      .where((entry) => entry.share != null)
      .map((entry) => entry.share!.text)
      .join('\n\n');
}

/// Create one link per item in sequence. Failed or ambiguous writes are never
/// retried automatically: an upstream may already have accepted the request.
class BatchShareJob extends ValueNotifier<BatchShareReport> {
  BatchShareJob(List<CloudFile> files, this.options)
    : files = List.unmodifiable(files),
      super(BatchShareReport(files.length, const []));
  final List<CloudFile> files;
  final ShareOptions options;
  final _scope = RequestScope();
  bool _started = false;

  void stop() => _scope.cancel();

  Future<void> run(
    Future<ShareCreation> Function(CloudFile, ShareOptions) create, {
    required void Function() guard,
  }) async {
    if (_started) return;
    _started = true;
    final entries = <BatchShareEntry>[];
    String? reason;
    await _scope.run(() async {
      for (final file in files) {
        try {
          RequestScope.checkpoint();
          guard();
        } catch (error) {
          reason = _scope.token.isCancelled ? '已停止，已创建的分享仍可复制' : _error(error);
          break;
        }
        try {
          final share = await RequestScope.cancellable(
            create(
              file,
              ShareOptions(
                file.displayName,
                expiryDays: options.expiryDays,
                passcode: options.passcode,
              ),
            ),
          );
          entries.add(BatchShareEntry(file, share: share));
        } catch (error) {
          entries.add(
            BatchShareEntry(
              file,
              error: _scope.token.isCancelled
                  ? '已停止，当前请求结果未确认，请到网盘查看'
                  : _error(error),
            ),
          );
        }
        value = BatchShareReport(files.length, List.unmodifiable(entries));
      }
    });
    if (_scope.token.isCancelled) reason ??= '已停止，已创建的分享仍可复制';
    value = BatchShareReport(
      files.length,
      List.unmodifiable(entries),
      finished: true,
      reason: reason,
    );
  }

  static String _error(Object error) =>
      error is AppException ? error.message : '创建失败，请稍后手动重试';
}
