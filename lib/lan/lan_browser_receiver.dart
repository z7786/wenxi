import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/json.dart';
import '../data/http.dart';
import '../data/state_store.dart';
import '../diagnostics/app_log.dart';
import '../download/space_budget.dart';
import '../platform/file_access.dart';
import 'lan_models.dart';

const lanBrowserChunkSize = 2 * 1024 * 1024;

class LanBrowserException extends AppException {
  const LanBrowserException(super.message, this.status);
  final int status;
}

enum LanBrowserUploadState {
  waiting('等待上传'),
  receiving('正在接收'),
  paused('等待继续'),
  verifying('正在校验'),
  saving('正在保存'),
  completed('已保存'),
  failed('接收失败'),
  cancelled('已取消');

  const LanBrowserUploadState(this.label);
  final String label;
}

class LanBrowserUpload {
  LanBrowserUpload({
    required this.id,
    required this.owner,
    required this.sender,
    required this.path,
    required this.size,
    required this.sha256,
    required this.createdAt,
    this.destination,
    this.state = LanBrowserUploadState.waiting,
    this.savedPath,
  }) : updatedAt = createdAt;

  final String id, owner, sender, path, sha256;
  final String? destination;
  final int size;
  final DateTime createdAt;
  DateTime updatedAt;
  LanBrowserUploadState state;
  int offset = 0, copied = 0;
  String error = '';
  String? savedPath;
  RequestScope? _scope;
  Future<void>? _operation;
  StoragePlan? _storage;

  String get name => p.posix.basename(path);
  String get directory =>
      p.posix.dirname(path) == '.' ? '' : p.posix.dirname(path);
  bool get busy => _operation != null;
  bool get finished =>
      state == LanBrowserUploadState.completed ||
      state == LanBrowserUploadState.cancelled;
  bool get canSave => !busy && !finished && offset == size;

  Json toJson({bool local = false}) => {
    'id': id,
    'path': path,
    'size': size,
    'sha256': sha256,
    'offset': offset,
    'copied': copied,
    'state': state.name,
    'error': error,
    if (local) ...{
      'sender': sender,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'savedPath': savedPath,
    },
  };

  factory LanBrowserUpload.fromReceipt(Json value) {
    require(
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value.str('id')) &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(value.str('sha256')) &&
          value.integer('size', -1) >= 0 &&
          value.integer('size') <= 16 * 1024 * 1024 * 1024 * 1024 &&
          value.integer('createdAt', -1) >= 0 &&
          value.integer('createdAt') <= 8640000000000000 &&
          value.str('savedPath').isNotEmpty,
      '网页接收记录无效',
    );
    final upload = LanBrowserUpload(
      id: value.str('id'),
      owner: '',
      sender: value.str('sender').ifEmpty('网页浏览器'),
      path: lanRelativePath(value.str('path')),
      size: value.integer('size'),
      sha256: value.str('sha256'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        value.integer('createdAt'),
      ),
      state: LanBrowserUploadState.completed,
      savedPath: value.str('savedPath'),
    );
    upload.offset = upload.copied = upload.size;
    return upload;
  }
}

/// Owns pushed file bodies only. Publishing and capacity reservations use the
/// same platform file access and space budget as ordinary downloads.
class LanBrowserReceiver extends ChangeNotifier {
  LanBrowserReceiver({
    required this.store,
    required this.cache,
    required this.files,
    required this.destination,
    SpaceBudget Function()? budget,
    DateTime Function()? clock,
    this.idleRetention = const Duration(minutes: 30),
  }) : _budget = budget,
       clock = clock ?? DateTime.now {
    for (final value in store.data.list('lanBrowserReceipts').take(100)) {
      try {
        _receipts.add(LanBrowserUpload.fromReceipt(value));
      } on AppException {
        // An invalid history row never changes a user file or blocks startup.
      }
    }
  }

  final StateStore store;
  final Directory cache;
  final FileAccess files;
  final String? Function() destination;
  final SpaceBudget Function()? _budget;
  final DateTime Function() clock;
  final Duration idleRetention;
  final _prepareGate = AsyncGate(), _historyGate = AsyncGate();
  final _uploads = <String, LanBrowserUpload>{};
  final _receipts = <LanBrowserUpload>[];
  late final _ownBudget = SpaceBudget(() => files.freeBytes(cache.path));
  String? _root;
  bool _running = false, _disposed = false;
  int _active = 0;
  Timer? _notification;

  SpaceBudget get _space => _budget?.call() ?? _ownBudget;
  int get activeOperations => _active;
  List<LanBrowserUpload> get records => List.unmodifiable([
    ..._uploads.values
        .where((u) => u.state != LanBrowserUploadState.completed)
        .toList()
        .reversed,
    ..._receipts,
  ]);

  void _changed({bool progress = false}) {
    if (_disposed) return;
    if (progress) {
      _notification ??= Timer(const Duration(milliseconds: 200), () {
        _notification = null;
        _changed();
      });
    } else {
      notifyListeners();
    }
  }

  Future<void> start() async {
    if (_running) return;
    require(!_disposed, '网页接收已关闭');
    await cache.create(recursive: true);
    _root = await cache.resolveSymbolicLinks();
    // Only our immediately contained random .part files are temporary. Never
    // traverse a directory or remove any exported destination on restart.
    await for (final entry in Directory(_root!).list(followLinks: false)) {
      if (entry is File &&
          RegExp(r'^[a-f0-9]{32}\.part$').hasMatch(p.basename(entry.path)) &&
          p.equals(entry.absolute.parent.path, _root!)) {
        await entry.delete();
      }
    }
    _running = true;
    _uploads.clear();
  }

  File _payload(LanBrowserUpload upload) =>
      File(p.join(_root!, '${upload.id}.part'));

  void _check(LanBrowserUpload upload) {
    if (!_running ||
        upload.state == LanBrowserUploadState.cancelled ||
        upload._scope?.token.isCancelled == true) {
      throw const LanBrowserException('传输已取消，请重新选择文件', 410);
    }
    RequestScope.checkpoint();
  }

  LanBrowserUpload upload(String owner, String id) {
    final value = _uploads[id];
    if (value == null || value.owner != owner) {
      throw const LanBrowserException('传输不存在，请重新选择文件', 404);
    }
    return value;
  }

  List<Json> status(String owner) => _uploads.values
      .where((u) => u.owner == owner)
      .map((u) => u.toJson())
      .toList();

  Future<void> _reserve(LanBrowserUpload upload) async {
    final plan = upload._storage ??= await files.storagePlan(
      _root!,
      upload.destination,
    );
    final volumes = {
      plan.cache.id: plan.cache.path,
      plan.target.id: plan.target.path,
    };
    await _space.reserveVolumes(
      'lan-web/${upload.id}',
      plan.requirements(upload.size, upload.offset),
      availableOnVolume: (volume) => files.freeBytes(volumes[volume]!),
    );
  }

  Future<LanBrowserUpload> prepare(
    String owner,
    String sender,
    Json metadata,
  ) => _prepareGate.run(() async {
    if (!_running) throw const LanBrowserException('网页接收尚未开启', 503);
    final id = metadata.str('id'), digest = metadata.str('sha256');
    final rawSize = metadata['size'];
    final size = metadata.integer('size', -1);
    final rawPath = metadata.str('path').replaceAll('\\', '/');
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        rawSize is! num ||
        rawSize != size ||
        size < 0 ||
        size > 16 * 1024 * 1024 * 1024 * 1024 ||
        rawPath.isEmpty ||
        rawPath.length > 2048 ||
        rawPath.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const LanBrowserException('文件信息无效', 400);
    }
    final path = lanRelativePath(
      rawPath.split('/').map(safeFileName).join('/'),
    );
    final previous = _uploads[id];
    if (previous != null) {
      if (previous.owner != owner ||
          previous.path != path ||
          previous.size != size ||
          previous.sha256 != digest) {
        throw const LanBrowserException('传输标识与文件不匹配，请重新选择文件', 409);
      }
      if (!previous.finished) previous.updatedAt = clock();
      return previous;
    }
    if (_uploads.values.where((u) => !u.finished).length >= 32) {
      throw const LanBrowserException('接收队列已满，请完成或取消已有传输', 429);
    }
    final value = LanBrowserUpload(
      id: id,
      owner: owner,
      sender: sender,
      path: path,
      size: size,
      sha256: digest,
      createdAt: clock(),
      destination: destination(),
    );
    try {
      await _reserve(value);
      if (!_running) throw const LanBrowserException('设备互联已关闭', 410);
      await _payload(value).create(exclusive: true);
    } catch (_) {
      _space.release('lan-web/$id');
      rethrow;
    }
    _uploads[id] = value;
    _trim();
    _changed();
    return value;
  });

  void _trim() {
    final closed = _uploads.values.where((u) => u.finished && !u.busy).toList();
    for (final value in closed.take(
      (closed.length - 100).clamp(0, closed.length),
    )) {
      _uploads.remove(value.id);
    }
  }

  Future<void> _perform(
    LanBrowserUpload value,
    Future<void> Function() action,
  ) async {
    if (value.busy) throw const LanBrowserException('此文件正在处理，请稍后重试', 409);
    _check(value);
    if (_active >= 2) throw const LanBrowserException('接收端忙，请稍后重试', 503);
    final done = Completer<void>();
    value._operation = done.future;
    value._scope = RequestScope();
    _active++;
    _changed();
    try {
      await value._scope!.run(action);
    } catch (error) {
      if (!value.finished) {
        value.state = value._scope!.token.isCancelled || !_running
            ? LanBrowserUploadState.cancelled
            : error is SocketException ||
                  error is HttpException ||
                  error is TimeoutException
            ? LanBrowserUploadState.paused
            : LanBrowserUploadState.failed;
        value.error = error is AppException
            ? error.message
            : value.state == LanBrowserUploadState.paused
            ? '连接中断，已收到的进度已保留，请重试'
            : '无法写入或保存文件，请检查空间和目录权限后重试';
        DiagnosticLog.event(
          'lan.web_receive_failed',
          fields: {
            'state': value.state.name,
            'size': value.size,
            'offset': value.offset,
            if (error is FileSystemException) 'errno': error.osError?.errorCode,
          },
        );
      }
      if (error is LanBrowserException) rethrow;
      throw LanBrowserException(
        value.error,
        error is DownloadSpaceException ? 507 : 409,
      );
    } finally {
      _active--;
      value._scope = null;
      value._operation = null;
      value.updatedAt = clock();
      done.complete();
      _changed();
    }
  }

  Future<LanBrowserUpload> append(
    String owner,
    String id,
    int offset,
    int length,
    Stream<List<int>> body,
  ) async {
    final value = upload(owner, id);
    if (value.finished ||
        offset != value.offset ||
        length < 1 ||
        offset + length > value.size) {
      throw const LanBrowserException('上传位置已变化，请读取进度后继续', 409);
    }
    if (length > lanBrowserChunkSize) {
      throw const LanBrowserException('上传分块过大', 413);
    }
    await _perform(value, () async {
      await _reserve(value);
      _check(value);
      value.state = LanBrowserUploadState.receiving;
      value.error = '';
      _changed();
      // An incomplete HTTP body must not become an acknowledged file prefix.
      // At most two fixed-size blocks are buffered, irrespective of file size.
      final data = BytesBuilder(copy: false);
      final iterator = StreamIterator(
        body.timeout(const Duration(seconds: 45)),
      );
      try {
        while (await RequestScope.cancellable(iterator.moveNext())) {
          _check(value);
          if (data.length + iterator.current.length > length) {
            throw const LanBrowserException('上传内容超出声明的分块大小', 400);
          }
          data.add(iterator.current);
        }
      } finally {
        await iterator.cancel();
      }
      if (data.length != length) {
        throw const HttpException('Incomplete upload block');
      }
      _check(value);
      final file = _payload(value);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const LanBrowserException('接收缓存已被移除，请取消后重新选择文件', 409);
      }
      final output = await file.open(mode: FileMode.append);
      try {
        if (await output.length() < value.offset) {
          throw const LanBrowserException('接收缓存已变化，请取消后重新选择文件', 409);
        }
        await output.truncate(value.offset);
        await output.setPosition(value.offset);
        _check(value);
        await output.writeFrom(data.takeBytes());
        await output.flush();
        // Only advance after durable completion. A lost response is recovered
        // by GET status; resending the previous offset cannot duplicate bytes.
        value.offset += length;
        _space.consume('lan-web/${value.id}', value._storage!.cache.id, length);
      } finally {
        await output.close();
      }
      value.state = LanBrowserUploadState.paused;
      value.updatedAt = clock();
      _changed(progress: true);
    });
    return value;
  }

  LanBrowserUpload complete(String owner, String id) {
    final value = upload(owner, id);
    if (value.state == LanBrowserUploadState.completed ||
        value.busy &&
            (value.state == LanBrowserUploadState.verifying ||
                value.state == LanBrowserUploadState.saving)) {
      return value;
    }
    if (value.offset != value.size) {
      throw const LanBrowserException('文件尚未传完，请继续上传', 409);
    }
    if (value.busy || _active >= 2) {
      throw const LanBrowserException('接收端忙，请稍后重试', 503);
    }
    _check(value);
    // Final verification/export outlives its HTTP reply, so a browser timeout
    // or refresh cannot export the same complete file a second time.
    value.state = LanBrowserUploadState.verifying;
    unawaited(
      _perform(value, () async {
        final file = _payload(value);
        value.error = '';
        await _reserve(value);
        _check(value);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const LanBrowserException('接收缓存已被移除，请取消后重新选择文件', 409);
        }
        if (await file.length() != value.size) {
          throw const LanBrowserException('接收缓存已变化，请取消后重新选择文件', 409);
        }
        final digest = await crypto.sha256
            .bind(
              file.openRead().map((chunk) {
                _check(value);
                return chunk;
              }),
            )
            .first;
        _check(value);
        if (digest.toString() != value.sha256) {
          await file.writeAsBytes(const [], flush: true);
          value.offset = 0;
          throw const LanBrowserException('文件校验不一致，请重新上传', 422);
        }
        value.state = LanBrowserUploadState.saving;
        value.copied = 0;
        _changed();
        final saved = await files.save(
          id: value.id,
          source: file,
          name: value.name,
          relativePath: value.directory,
          destination: value.destination,
          checkpoint: () => _check(value),
          onProgress: (copied, total) {
            final delta = copied - value.copied;
            value.copied = copied;
            if (value._storage!.copyOnSave) {
              _space.consume('lan-web/$id', value._storage!.target.id, delta);
            }
            _changed(progress: true);
          },
        );
        // A returned platform path is a published file, including if stop was
        // requested just after publication. Record it before any cancellable work.
        value.savedPath = saved;
        value.copied = value.size;
        value.state = LanBrowserUploadState.completed;
        _receipts.insert(0, value);
        if (_receipts.length > 100) _receipts.removeLast();
        await _historyGate.run(() async {
          try {
            await store.put(
              'lanBrowserReceipts',
              _receipts.map((u) => u.toJson(local: true)).toList(),
            );
          } catch (_) {
            DiagnosticLog.event('lan.web_receipt_write_failed');
          }
        });
        _space.release('lan-web/$id');
        await _removePayload(value);
        DiagnosticLog.event(
          'lan.web_receive_completed',
          fields: {'size': value.size},
        );
      }).catchError((Object _) {}),
    );
    return value;
  }

  Future<void> _removePayload(LanBrowserUpload value) async {
    if (_root == null) return;
    try {
      final file = _payload(value);
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    } on FileSystemException {
      DiagnosticLog.event('lan.web_cache_cleanup_failed');
    }
  }

  Future<void> cancel(String owner, String id) async {
    final value = upload(owner, id);
    if (value.state == LanBrowserUploadState.completed) return;
    // Mark cancellation before any asynchronous platform call. This prevents
    // another HTTP request from starting work in the cleanup window.
    value.state = LanBrowserUploadState.cancelled;
    value._scope?.cancel();
    if (value.busy) {
      try {
        await files.cancelExport(value.id);
      } catch (_) {}
      await value._operation;
    }
    if (value.state == LanBrowserUploadState.completed) return;
    value.state = LanBrowserUploadState.cancelled;
    value.error = '';
    _space.release('lan-web/$id');
    await _removePayload(value);
    _trim();
    _changed();
  }

  Future<void> cancelOwner(String owner) async {
    for (final value
        in _uploads.values
            .where((u) => u.owner == owner && !u.finished)
            .toList()) {
      await cancel(owner, value.id);
    }
  }

  void prune() {
    for (final value in _uploads.values.toList()) {
      if (!value.busy &&
          !value.finished &&
          clock().difference(value.updatedAt) >= idleRetention) {
        unawaited(cancel(value.owner, value.id));
      }
    }
  }

  Future<void> stop() async {
    _running = false;
    // Join any queued preflight before sweeping the private payloads.
    await _prepareGate.run(() async {});
    for (final value in _uploads.values.where((u) => !u.finished).toList()) {
      await cancel(value.owner, value.id);
    }
    await Future.wait(
      _uploads.values.where((u) => u.busy).map((u) => u._operation!),
    );
    _notification?.cancel();
    _notification = null;
    _changed();
  }

  Future<void> close() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    dispose();
  }
}
