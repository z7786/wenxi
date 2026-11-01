import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../core/crypto_box.dart';
import '../core/json.dart';
import '../data/state_store.dart';

const nativeChannel = MethodChannel('com.asterlink.app/native');

abstract class NativeTransport {
  bool get connected;
  Future<Object?> call(String method, [Json args = const {}]);
  Future<void> dispose();
}

class AndroidGopeedTransport extends NativeTransport {
  bool _connected = false;
  bool _parserUsed = false;
  @override
  bool get connected => _connected;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    try {
      if (method == 'parserRequestStart') _parserUsed = true;
      final value = await nativeChannel.invokeMethod<Object?>('gopeed', {
        'method': method,
        'args': jsonEncode(args),
      });
      if (method == 'open') _connected = true;
      if (method == 'close') {
        _connected = false;
        _parserUsed = false;
      }
      return value is String ? jsonDecode(value) : value;
    } on PlatformException catch (e) {
      throw AppException(e.message ?? '下载组件操作失败');
    }
  }

  @override
  Future<void> dispose() async {
    if (_connected || _parserUsed) await call('close');
  }
}

class DesktopGopeedTransport extends NativeTransport {
  DesktopGopeedTransport({required this.executable, this.launchProcess});
  final String executable;
  final Future<Process> Function(String executable)? launchProcess;
  Process? _process;
  final _starting = AsyncGate(), _writer = AsyncGate();
  final _pending = <int, Completer<Object?>>{};
  int _sequence = 0;
  bool _disposed = false, _coreOpen = false;
  Future<void>? _disposeFuture;
  @override
  bool get connected => _process != null && _coreOpen;
  Future<Process> _start() => _starting.run(() async {
    require(!_disposed, '下载组件已经关闭');
    if (_process != null) return _process!;
    require(await File(executable).exists(), '缺少 Windows 下载组件，请安装完整版本');
    final Process process;
    try {
      process =
          await (launchProcess?.call(executable) ??
              Process.start(executable, const [], runInShell: false));
    } on ProcessException catch (error) {
      // Keep launch failures distinct from network errors. Changing download
      // URLs or retrying transfers cannot fix Windows application control.
      final blocked =
          {5, 577, 1260, 1275, 4551}.contains(error.errorCode) ||
          RegExp(
            r'应用程序控制|应用控制|application control|blocked.*policy',
            caseSensitive: false,
          ).hasMatch(error.message);
      throw AppException(
        blocked
            ? 'Windows 安全策略阻止了下载组件启动（错误 ${error.errorCode}）。'
                  '请检查 Windows 安全中心的保护历史记录或联系系统管理员，处理后重试；下载进度已保留'
            : 'Windows 下载组件无法启动（错误 ${error.errorCode}），'
                  '请重新安装完整版本后重试；下载进度已保留',
      );
    }
    _coreOpen = false;
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!identical(_process, process)) return;
            try {
              final result = asJson(jsonDecode(line));
              final waiter = _pending.remove(result.integer('seq'));
              if (waiter == null) return;
              if (result.str('error').isNotEmpty) {
                waiter.completeError(AppException(result.str('error')));
              } else {
                waiter.complete(result['result']);
              }
            } catch (_) {
              _fail(const AppException('下载组件响应格式错误'));
            }
          },
          onError: (Object _) {
            if (identical(_process, process)) {
              _fail(const AppException('下载组件连接中断'));
            }
          },
        );
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((_) {
        if (!identical(_process, process)) return;
        _process = null;
        _coreOpen = false;
        _fail(const AppException('下载组件已退出，进度已保留，请重试'));
      }),
    );
    return process;
  });
  void _fail(AppException error) {
    final values = _pending.values.toList();
    _pending.clear();
    for (final waiter in values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
  }

  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    final process = await _start();
    final seq = ++_sequence, waiter = Completer<Object?>();
    _pending[seq] = waiter;
    unawaited(
      _writer.run(() async {
        try {
          require(identical(process, _process), '下载组件连接已中断');
          process.stdin.writeln(
            jsonEncode({'seq': seq, 'method': method, 'args': args}),
          );
          await process.stdin.flush();
        } catch (_) {
          if (!waiter.isCompleted) {
            waiter.completeError(const AppException('下载组件通信失败'));
          }
        }
      }),
    );
    try {
      final result = await waiter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw const AppException('下载组件响应超时，进度已保留'),
      );
      if (identical(_process, process)) {
        if (method == 'open') _coreOpen = true;
        if (method == 'close') _coreOpen = false;
      }
      return result;
    } finally {
      _pending.remove(seq);
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    if (_disposed) return;
    try {
      if (_process != null) await call('close');
    } finally {
      _disposed = true;
      _coreOpen = false;
      final process = _process;
      _process = null;
      try {
        if (process != null) {
          try {
            // A response can arrive before stdin.flush completes. Drain the
            // writer before closing the sink, including pending status polls.
            await _writer.run(() async => await process.stdin.close());
          } finally {
            process.kill();
            await process.exitCode;
          }
        }
      } finally {
        _fail(const AppException('下载组件已关闭'));
      }
    }
  }
}

/// Cold deletion records a marker; it never loads JNI just to remove a row.
class GopeedEngine {
  static const destinationCacheName = '.asterlink-cache';
  GopeedEngine(
    this.transport,
    this.store,
    this.vault,
    this.storage,
    this.cache,
  );
  final NativeTransport transport;
  final StateStore store;
  final CredentialStore vault;
  final Directory storage, cache;
  final _gate = AsyncGate();
  bool _started = false;
  bool? _taskCacheRootsSupported;
  bool? _directOutputSupported;
  bool? _sourceNetworkPolicySupported;
  bool? _ed2kSupported;
  void validateId(String id) =>
      require(RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id), '无效的下载任务编号');
  Future<void> _start() async {
    if (!_started || !transport.connected) {
      await storage.create(recursive: true);
      await cache.create(recursive: true);
      var key = vault.secret('flutter.gopeed.key');
      if (key == null) {
        key = base64Encode(CryptoBox.random(32));
        await vault.putSecret('flutter.gopeed.key', key);
      }
      final opened = asJson(
        await transport.call('open', {
          'storageDir': storage.path,
          'cacheDir': cache.path,
          'storageGeneration': store.data.str('engineStorageGeneration'),
          'key': key,
        }),
      );
      // Android upgrades may retain an older native database key. Keep the
      // actual key in encrypted state so password recovery protects it too.
      final actualKey = opened.str('key');
      if (actualKey.isNotEmpty && actualKey != key) {
        try {
          require(
            actualKey.length <= 128 && base64Decode(actualKey).length == 32,
            '下载组件密钥格式错误',
          );
        } on FormatException {
          throw const AppException('下载组件密钥格式错误');
        }
        await vault.putSecret('flutter.gopeed.key', actualKey);
      }
      _started = true;
      _taskCacheRootsSupported = null;
      _directOutputSupported = null;
      _sourceNetworkPolicySupported = null;
      _ed2kSupported = null;
    }
    final pending = (store.data['nativeRemovals'] as List? ?? [])
        .map((e) => e.toString())
        .toList();
    final removed = <String>{};
    try {
      for (final id in pending) {
        validateId(id);
        try {
          await transport.call('remove', {'id': id});
        } catch (_) {
          // A forgotten history row must not prevent unrelated downloads from
          // starting. Its durable removal marker remains available for retry.
          continue;
        }
        removed.add(id);
      }
    } finally {
      await _forgetRemovals(removed);
    }
  }

  Future<void> _forgetRemovals(Set<String> ids) async {
    if (ids.isEmpty ||
        !(store.data['nativeRemovals'] as List? ?? []).any(ids.contains)) {
      return;
    }
    await store.change((draft) {
      draft['nativeRemovals'] = (draft['nativeRemovals'] as List? ?? [])
          .where((value) => !ids.contains(value))
          .toList();
    });
  }

  Future<Json> torrentCall(String method, Json args) => _gate.run(() async {
    validateId(args.str('id'));
    require(
      {
        'torrentResolve',
        'torrentMetadata',
        'torrentCancel',
        'torrentStreamStart',
        'torrentStreamStatus',
        'torrentStreamStop',
        'torrentStreamInterrupt',
      }.contains(method),
      '无效的 BT 操作',
    );
    if (method == 'torrentResolve' || method == 'torrentStreamStart') {
      await _start();
    }
    if ({
          'torrentCancel',
          'torrentStreamStop',
          'torrentStreamInterrupt',
        }.contains(method) &&
        (!_started || !transport.connected)) {
      return <String, dynamic>{};
    }
    require(_started && transport.connected, '下载组件连接已中断');
    return asJson(await transport.call(method, args));
  });

  Future<Json> httpProbeCall(String method, Json args) => _gate.run(() async {
    validateId(args.str('id'));
    require(
      {'httpProbeStart', 'httpProbeStatus', 'httpProbeStop'}.contains(method),
      '无效的下载连接检查',
    );
    if (method == 'httpProbeStart') await _start();
    if (method == 'httpProbeStop' && (!_started || !transport.connected)) {
      return <String, dynamic>{};
    }
    require(_started && transport.connected, '下载组件连接已中断');
    return asJson(await transport.call(method, args));
  });

  Future<void> requireDirectOutput() => _gate.run(() async {
    await _start();
    _directOutputSupported ??= asJson(
      await transport.call('version'),
    ).boolean('directOutput');
    require(_directOutputSupported!, '下载组件版本过旧，请安装支持直接下载的完整新版应用');
  });

  Future<void> begin(Json request) => _gate.run(() async {
    final id = request.str('id');
    validateId(id);
    await _start();
    if (request.str('url').toLowerCase().startsWith('ed2k://')) {
      _ed2kSupported ??= asJson(
        await transport.call('version'),
      ).boolean('ed2k');
      require(_ed2kSupported!, '下载组件版本过旧，请安装支持 ED2K 的完整新版应用');
    }
    if (request['networkPolicy'] != null) {
      _sourceNetworkPolicySupported ??= asJson(
        await transport.call('version'),
      ).boolean('sourceNetworkPolicy');
      require(_sourceNetworkPolicySupported!, '下载组件版本过旧，请安装支持来源接入包的完整新版应用');
    }
    if (request.str('outputPath').isNotEmpty) {
      _directOutputSupported ??= asJson(
        await transport.call('version'),
      ).boolean('directOutput');
      require(_directOutputSupported!, '下载组件版本过旧，请安装支持直接下载的完整新版应用');
    }
    require(
      !(store.data['nativeRemovals'] as List? ?? []).contains(
        request.str('id'),
      ),
      '此任务的旧下载缓存尚未清理，请重试',
    );
    final root = taskCacheRoot(id);
    final customCache = !p.equals(root.path, cache.path);
    if (customCache) {
      _taskCacheRootsSupported ??= asJson(
        await transport.call('version'),
      ).boolean('taskCacheRoots');
      require(_taskCacheRootsSupported!, '下载组件版本过旧，无法使用所选目录作为缓存，请安装完整新版应用');
      await checkedTaskDirectory(id, create: true);
    }
    await transport.call('begin', {
      ...request,
      if (customCache) 'cacheRoot': root.path,
    });
  });
  Future<Json> snapshot(String id) => _gate.run(() async {
    validateId(id);
    require(_started && transport.connected, '下载组件连接中断，请继续任务');
    return asJson(await transport.call('snapshot', {'id': id}));
  });
  Future<void> pause(String id) => _gate.run(() async {
    validateId(id);
    if (_started && transport.connected) {
      await transport.call('pause', {'id': id});
    }
  });

  /// Returns whether the native record was removed now. A durable history
  /// cleanup can acknowledge many removals in its own state transaction.
  Future<bool> remove(String id, {bool deferPersistence = false}) =>
      _gate.run(() async {
        validateId(id);
        if (_started && transport.connected) {
          await transport.call('remove', {'id': id});
          if (!deferPersistence) await _forgetRemovals({id});
          return true;
        }
        if (!(store.data['nativeRemovals'] as List? ?? []).contains(id)) {
          await store.change((draft) {
            draft['nativeRemovals'] = <String>{
              ...(draft['nativeRemovals'] as List? ?? []).map((e) => '$e'),
              id,
            }.toList();
          });
        }
        return false;
      });
  Future<void> close() => _gate.run(() async {
    await transport.dispose();
    _started = false;
  });
  Directory taskCacheRoot(String id) {
    validateId(id);
    final roots = store.data['downloadCacheRoots'];
    final value = roots is Map ? roots[id] : null;
    if (value == null) return cache;
    require(
      value is String &&
          p.isAbsolute(value) &&
          p.basename(p.normalize(value)) == destinationCacheName,
      '下载缓存目录无效，请重新添加任务',
    );
    return Directory(p.normalize(value as String));
  }

  Directory taskDirectory(String id) {
    final root = taskCacheRoot(id);
    final path = p.normalize(p.join(root.path, id));
    require(p.equals(p.dirname(path), p.normalize(root.path)), '无效的缓存路径');
    return Directory(path);
  }

  Future<Directory?> checkedTaskDirectory(
    String id, {
    bool create = false,
  }) async {
    final root = taskCacheRoot(id), directory = taskDirectory(id);
    for (final item in [root, directory]) {
      var type = await FileSystemEntity.type(item.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!create) return null;
        await item.create(recursive: true);
        type = await FileSystemEntity.type(item.path, followLinks: false);
      }
      // Existing installations may redirect the legacy cache root. Keep that
      // compatibility; a task directory itself must never be a link.
      if (identical(item, root) &&
          p.equals(root.path, cache.path) &&
          type == FileSystemEntityType.link &&
          await root.exists()) {
        continue;
      }
      require(type == FileSystemEntityType.directory, '下载缓存路径发生变化，已停止操作');
    }
    final resolvedRoot = await root.resolveSymbolicLinks();
    final resolvedTask = await directory.resolveSymbolicLinks();
    require(
      p.equals(resolvedTask, p.join(resolvedRoot, id)),
      '下载缓存路径发生变化，已停止操作',
    );
    return directory;
  }
}
