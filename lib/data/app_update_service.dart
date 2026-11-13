import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../diagnostics/app_log.dart';
import '../domain/downloads.dart';
import '../domain/links.dart';
import '../domain/github.dart';
import '../domain/models.dart';
import '../domain/remote_control.dart';
import '../download/download_manager.dart';
import '../download/mobile_data_download_guard.dart';
import '../platform/app_update_installer.dart';
import '../platform/file_access.dart';
import 'cloud_repository.dart';

class AppUpdateService extends ChangeNotifier {
  AppUpdateService({
    required this.platform,
    required this.cloud,
    required this.downloads,
    required this.files,
    required this.installer,
    required this.currentUpdate,
    required this.inForeground,
    required this.openDownloads,
  }) {
    downloads.addListener(_changed);
  }

  final String platform;
  final CloudRepository cloud;
  final DownloadManager downloads;
  final FileAccess files;
  final AppUpdateInstaller installer;
  final RemoteUpdate? Function() currentUpdate;
  final bool Function() inForeground;
  final VoidCallback openDownloads;
  final _pending = <String, Future<bool>>{};
  final _errors = <String, String>{};
  final _stages = <String, String>{};
  bool _closed = false;

  bool get supported => {'android', 'windows', 'macos'}.contains(platform);

  String keyFor(RemoteUpdate update) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            platform,
            update.key,
            update.version,
            update.appDownloadUrl.toString(),
            update.inAppPasscode,
          ]),
        ),
      )
      .toString();

  DownloadTask? taskFor(RemoteUpdate update) {
    final key = keyFor(update);
    return downloads.tasks
        .where(
          (task) =>
              task.spec.appUpdateKey == key &&
              task.status != DownloadStatus.cancelled,
        )
        .firstOrNull;
  }

  bool busy(RemoteUpdate update) => _pending.containsKey(keyFor(update));
  String stage(RemoteUpdate update) => _stages[keyFor(update)] ?? '';
  String? error(RemoteUpdate update) => _errors[keyFor(update)];

  void _changed() {
    if (!_closed) notifyListeners();
  }

  void _checkCurrent(RemoteUpdate update) {
    final current = currentUpdate();
    require(
      !_closed && current != null && keyFor(current) == keyFor(update),
      '更新信息已变化，请按最新提示重试',
    );
  }

  Future<bool> _perform(RemoteUpdate update, Future<void> Function() action) {
    if (_closed) return Future.value(false);
    final key = keyFor(update);
    if (_pending[key] case final pending?) return pending;
    _errors.remove(key);
    // Schedule after registering the operation so synchronous listeners cannot
    // enqueue or install the same release twice.
    final work = Future<void>.microtask(action)
        .then((_) => true)
        .catchError((Object error, StackTrace stack) {
          if (error is DownloadConfirmationCancelled) return false;
          if (!_closed) {
            _errors[key] = error is AppException
                ? error.message
                : '更新操作失败，请重试或使用浏览器更新';
            DiagnosticLog.error('update.in_app_failed', error, stack);
          }
          return false;
        })
        .whenComplete(() {
          _pending.remove(key);
          _stages.remove(key);
          _changed();
        });
    _pending[key] = work;
    _changed();
    return work;
  }

  void _stage(RemoteUpdate update, String text) {
    _stages[keyFor(update)] = text;
    _changed();
  }

  Future<bool> start(RemoteUpdate update, {bool redownload = false}) =>
      _perform(update, () async {
        require(supported, '当前平台请使用浏览器更新');
        _checkCurrent(update);
        final existing = taskFor(update);
        if (existing != null) {
          if (existing.active) return;
          if (redownload) {
            await downloads.delete(existing.id);
            _checkCurrent(update);
          } else if (existing.status == DownloadStatus.completed) {
            final availability = await files.inspect(existing.savedPath);
            _checkCurrent(update);
            if (availability == FileAvailability.present) return;
            require(
              availability == FileAvailability.missing,
              '无法访问已下载的安装包，请恢复下载目录权限后重试',
            );
            await downloads.delete(existing.id);
            _checkCurrent(update);
          } else {
            await downloads.resume(existing.id);
            return;
          }
        }
        _stage(update, '正在解析更新链接…');
        final spec = await resolve(update);
        _checkCurrent(update);
        await downloads.enqueue(spec.copyWith(appUpdateKey: keyFor(update)));
      });

  Future<DownloadSpec> resolve(RemoteUpdate update) async {
    final url = httpsUri(update.appDownloadUrl.toString());
    // Release installation links remain independent of the optional GitHub
    // account/provider and its API quota, including the fallback update feed.
    if (GitHubLink.parse(url)?.isReleaseAsset == true) {
      final name = url.pathSegments.lastOrNull ?? '';
      AppUpdateInstaller.requirePackageName(name, platform);
      return DownloadSpec(url: url.toString(), fileName: name);
    }
    final links = LinkParser.parse(url.toString());
    require(links.length == 1, '更新链接无效，请使用浏览器更新');
    var link = links.single;
    if (update.inAppPasscode.isNotEmpty) {
      link = link.withPasscode(update.inAppPasscode);
    }
    if (link.kind == LinkKind.cloudShare && link.platform != null) {
      final session = await cloud.share(
        link,
        preferQuarkMobileTransfer: link.platform == CloudPlatform.quark,
      );
      _checkCurrent(update);
      final entries = await cloud.list(session, session.rootId);
      _checkCurrent(update);
      require(
        entries.length == 1 && !entries.single.isDirectory,
        '更新链接必须只包含一个安装包，不能包含文件夹或多个文件，请使用浏览器更新',
      );
      final file = entries.single;
      AppUpdateInstaller.requirePackageName(file.name, platform);
      return cloud.planDownload(session, file);
    }
    require(
      link.kind == LinkKind.direct && link.platform == null,
      '暂不支持解析此更新链接，请使用浏览器更新',
    );
    final name = url.pathSegments.lastOrNull ?? '';
    require(
      AppUpdateInstaller.supportsName(name, platform),
      '此地址不是可识别的安装包直链或已支持的网盘分享，请使用浏览器更新',
    );
    return DownloadSpec(url: url.toString(), fileName: name);
  }

  Future<bool> pause(RemoteUpdate update) => _perform(update, () async {
    final task = taskFor(update);
    if (task != null) await downloads.pause(task.id);
  });

  Future<bool> install(RemoteUpdate update, {bool Function()? canOpen}) =>
      _perform(update, () async {
        _checkCurrent(update);
        require(inForeground(), '请回到应用后点击立即安装');
        final task = taskFor(update);
        require(
          task?.status == DownloadStatus.completed && task?.savedPath != null,
          '安装包尚未下载完成',
        );
        require(
          await files.inspect(task!.savedPath) == FileAvailability.present,
          '安装包不存在或无法访问，请重新下载或使用浏览器更新',
        );
        _stage(update, '正在校验安装包…');
        final path = await installer.prepare(task, update);
        _checkCurrent(update);
        require(inForeground(), '安装包已就绪，请回到应用后点击立即安装');
        require(canOpen?.call() ?? true, '安装包已就绪，请重新打开更新弹窗后点击立即安装');
        require(
          downloads.task(task.id)?.savedPath == task.savedPath,
          '下载记录已变化，请重新下载',
        );
        _stage(
          update,
          platform == 'windows' &&
                  task.spec.fileName.toLowerCase().endsWith('.zip')
              ? '正在打开文件夹…'
              : '正在打开安装器…',
        );
        await installer.open(path, task.spec.fileName);
      });

  void close() {
    if (_closed) return;
    _closed = true;
    downloads.removeListener(_changed);
    dispose();
  }
}
