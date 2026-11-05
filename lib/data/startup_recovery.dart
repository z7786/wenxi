import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import '../core/crypto_box.dart';
import '../core/json.dart';
import 'backup.dart';
import 'state_key.dart';
import 'state_store.dart';

class StartupRecoveryResult {
  const StartupRecoveryResult(this.archive, {this.accounts = 0});
  final Directory archive;
  final int accounts;
}

/// Recovery never opens a cloud connection or starts the download engine.
class StartupRecovery {
  const StartupRecovery(
    this.failure, {
    this.storage = StateStore.secureStorage,
    this.localKey,
  });
  final StateRecoveryRequired failure;
  final FlutterSecureStorage storage;
  final LocalStateKey? localKey;
  LocalStateKey get _localKey =>
      localKey ?? LocalStateKey(failure.directory, storage);
  static const _snapshots = [
    'state-v2.json',
    'state-v2.json.bak',
    'state-v2.json.tmp',
    'state-v1.enc',
    'state-v1.enc.bak',
    'state-v1.enc.tmp',
    ...LocalStateKey.sidecars,
  ];
  static final _gate = AsyncGate();

  Future<StartupRecoveryResult> restore(
    Uint8List bytes,
    String password,
  ) async {
    final prepared = StateStore.memory({'legacyImported': true});
    try {
      // Includes password, account, settings and favorite validation before any IO.
      final count = await BackupRepository(prepared).restore(bytes, password);
      return await _replace(prepared.data, accounts: count, password: password);
    } finally {
      prepared.dispose();
    }
  }

  Future<StartupRecoveryResult> reinitialize() =>
      _replace({'schema': 1, 'legacyImported': true});

  Future<bool> canUnlock() => _localKey.canUnlock();

  Future<void> unlock(String password) => _locked(() async {
    await _requireUnreadable();
    final localKey = _localKey;
    final key = await localKey.unlock(password);
    try {
      await StateStore.validateRecoveryKey(failure.directory, key);
      // Use a new backend even if the old one still returns values from memory.
      // Neither the encrypted state nor the engine generation is replaced.
      await localKey.saveFresh(key);
      final reopened = await StateStore.open(
        failure.directory,
        storage: storage,
        localKey: localKey,
      );
      reopened.dispose();
    } finally {
      key.fillRange(0, key.length, 0);
    }
  });

  Future<void> _requireUnreadable() async {
    try {
      final readable = await StateStore.open(
        failure.directory,
        storage: storage,
        localKey: _localKey,
      );
      readable.dispose();
    } on StateRecoveryRequired {
      return;
    }
    throw const AppException('本地数据已经可以读取，请点击重试进入应用');
  }

  Future<StartupRecoveryResult> _replace(
    Json data, {
    int accounts = 0,
    String? password,
  }) => _locked(() async {
    await _requireUnreadable();
    return _commit(failure.directory, data, accounts, password);
  });

  Future<T> _locked<T>(Future<T> Function() action) => _gate.run(() async {
    final directory = failure.directory;
    final lock = await File(
      p.join(directory.path, 'instance.lock'),
    ).open(mode: FileMode.append);
    try {
      try {
        await lock.lock(FileLock.exclusive);
      } on FileSystemException {
        throw const AppException('应用数据正在使用中，请关闭其他窗口后重试');
      }
      return await action();
    } finally {
      await lock.close();
    }
  });

  Future<StartupRecoveryResult> _commit(
    Directory directory,
    Json data,
    int accounts,
    String? password,
  ) async {
    data = {
      ...data,
      'schema': 1,
      'engineStorageGeneration': CryptoBox.random(
        16,
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
    };
    final archiveRoot = Directory(p.join(directory.path, 'state-recovery'));
    await archiveRoot.create(recursive: true);
    final archive = await archiveRoot.createTemp('saved-');
    final originals = <String>{};
    // Durable copies are made before any key or active snapshot changes.
    for (final name in _snapshots) {
      final original = File(p.join(directory.path, name));
      if (!await original.exists()) continue;
      final bytes = await original.readAsBytes();
      final copy = File(p.join(archive.path, name));
      await copy.writeAsBytes(bytes, flush: true);
      require(listEquals(bytes, await copy.readAsBytes()), '原数据保存失败，已停止恢复');
      originals.add(name);
    }
    final next = File(p.join(archive.path, 'replacement.json'));
    final bytes = await compute(encodePlainState, data);
    await next.writeAsBytes(bytes, flush: true);
    require(listEquals(bytes, await next.readAsBytes()), '恢复数据写入失败，原文件未修改');
    var snapshotsChanged = false;
    try {
      snapshotsChanged = true;
      for (final name in _snapshots.skip(1)) {
        final old = File(p.join(directory.path, name));
        if (await old.exists()) {
          await old.rename(p.join(archive.path, 'retired-$name'));
        }
      }
      // Startup repair can finish the pending snapshot after a process loss.
      final pending = await next.rename(
        p.join(directory.path, 'state-v2.json.tmp'),
      );
      await pending.rename(p.join(directory.path, 'state-v2.json'));
      final reopened = await StateStore.open(
        directory,
        storage: storage,
        localKey: _localKey,
      );
      try {
        require(jsonEncode(reopened.data) == jsonEncode(data), '恢复数据保存校验失败');
      } finally {
        reopened.dispose();
      }
      return StartupRecoveryResult(archive, accounts: accounts);
    } catch (error, stack) {
      try {
        if (snapshotsChanged) {
          for (final name in _snapshots) {
            final target = File(p.join(directory.path, name));
            if (originals.contains(name)) {
              final copy = File(p.join(archive.path, name));
              final rollback = File(p.join(directory.path, '$name.rollback'));
              await rollback.writeAsBytes(
                await copy.readAsBytes(),
                flush: true,
              );
              await rollback.rename(target.path);
            } else if (await target.exists()) {
              await target.delete();
            }
          }
        }
      } catch (_) {
        throw const AppException('恢复未完成，原数据文件已单独保存。请导出故障日志，暂勿卸载或清除数据');
      }
      Error.throwWithStackTrace(error, stack);
    }
  }
}
