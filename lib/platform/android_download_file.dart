import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Async file access through the Android document lease. [path] identifies the
/// native binding; it must never be reopened with dart:io.
class AndroidDownloadFile implements File {
  AndroidDownloadFile({
    required this.path,
    required this.id,
    required this.lease,
    required this.channel,
  });

  @override
  final String path;
  final String id, lease;
  final MethodChannel channel;
  static const chunkSize = 256 * 1024;
  static int _verificationToken = 0;

  Future<String?> digest(
    String algorithm, {
    required Future<void> cancelled,
  }) async {
    final token = ++_verificationToken;
    var finished = false;
    final operation = channel.invokeMethod<String>('verifyDownloadTarget', {
      'id': id,
      'lease': lease,
      'algorithm': algorithm,
      'token': token,
    });
    unawaited(
      cancelled.then((_) async {
        if (finished) return;
        try {
          await channel.invokeMethod<void>('cancelDownloadVerification', {
            'id': id,
            'token': token,
          });
        } catch (_) {
          // Always join the native reader before the manager releases its lease.
        }
      }),
    );
    try {
      final result = await operation;
      final length = switch (algorithm.toLowerCase().replaceAll('-', '')) {
        'md5' => 32,
        'sha1' => 40,
        'sha256' => 64,
        _ => 0,
      };
      if (result == null ||
          length == 0 ||
          result.length != length ||
          !RegExp(r'^[a-fA-F0-9]+$').hasMatch(result)) {
        throw FileSystemException('文件校验结果无效', path);
      }
      return result;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw FileSystemException(error.message ?? '无法校验下载文件', path);
    } finally {
      finished = true;
    }
  }

  Future<T?> access<T>(
    String operation, [
    Map<String, Object?> arguments = const {},
  ]) async {
    try {
      return await channel.invokeMethod<T>('downloadTargetIo', {
        'id': id,
        'lease': lease,
        'operation': operation,
        ...arguments,
      });
    } on PlatformException catch (error) {
      throw FileSystemException(error.message ?? '无法访问下载目标', path);
    }
  }

  @override
  Future<bool> exists() async => await access<bool>('exists') ?? false;

  @override
  Future<int> length() async {
    final result = await access<int>('length');
    if (result == null || result < 0) {
      throw FileSystemException('下载文件长度无效', path);
    }
    return result;
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final size = await length();
    if (mode == FileMode.write || mode == FileMode.writeOnly) {
      await access<void>('truncate', {'length': 0});
    }
    return _AndroidDownloadHandle(
      this,
      mode,
      mode == FileMode.append || mode == FileMode.writeOnlyAppend ? size : 0,
    );
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    final first = start ?? 0;
    RangeError.checkNotNegative(first, 'start');
    if (end != null && end < first) {
      throw RangeError.range(end, first, null, 'end');
    }
    final handle = await open();
    try {
      await handle.setPosition(first);
      var remaining = end == null ? null : end - first;
      while (remaining == null || remaining > 0) {
        final bytes = await handle.read(
          remaining == null ? chunkSize : math.min(chunkSize, remaining),
        );
        if (bytes.isEmpty) break;
        yield bytes;
        if (remaining != null) remaining -= bytes.length;
      }
    } finally {
      await handle.close();
    }
  }

  @override
  Future<Uint8List> readAsBytes() async {
    final result = BytesBuilder(copy: false);
    await for (final bytes in openRead()) {
      result.add(bytes);
    }
    return result.takeBytes();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      encoding.decode(await readAsBytes());

  @override
  File get absolute => this;

  @override
  Uri get uri => Uri.file(path);

  // Renaming, deleting and publishing belong to DownloadTargetStore. Synchronous
  // I/O cannot be implemented with a platform channel and is never used here.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unsupported download-file operation');
}

class _AndroidDownloadHandle implements RandomAccessFile {
  _AndroidDownloadHandle(this.file, this.mode, this._position);
  final AndroidDownloadFile file;
  final FileMode mode;
  int _position;
  bool _closed = false, _pending = false;

  @override
  String get path => file.path;

  void _checkOpen() {
    if (_closed || _pending) {
      throw FileSystemException(_closed ? '下载文件已关闭' : '下载文件操作尚未完成', path);
    }
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _checkOpen();
    _pending = true;
    try {
      return await action();
    } finally {
      _pending = false;
    }
  }

  void _requireWritable() {
    if (mode == FileMode.read) {
      throw FileSystemException('下载文件仅以读取方式打开', path);
    }
  }

  @override
  Future<Uint8List> read(int count) => _run(() async {
    RangeError.checkNotNegative(count, 'count');
    if (mode == FileMode.writeOnly || mode == FileMode.writeOnlyAppend) {
      throw FileSystemException('下载文件仅以写入方式打开', path);
    }
    final result = BytesBuilder(copy: false);
    var remaining = count;
    while (remaining > 0) {
      final size = math.min(remaining, AndroidDownloadFile.chunkSize);
      final bytes = await file.access<Uint8List>('read', {
        'offset': _position,
        'length': size,
      });
      if (bytes == null || bytes.length > size) {
        throw FileSystemException('下载文件读取结果无效', path);
      }
      if (bytes.isEmpty) break;
      result.add(bytes);
      _position += bytes.length;
      remaining -= bytes.length;
    }
    return result.takeBytes();
  });

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async {
    final limit = RangeError.checkValidRange(start, end, buffer.length);
    final bytes = await read(limit - start);
    buffer.setRange(start, start + bytes.length, bytes);
    return bytes.length;
  }

  @override
  Future<int> readByte() async {
    final bytes = await read(1);
    return bytes.isEmpty ? -1 : bytes.single;
  }

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) => _run(() async {
    _requireWritable();
    final limit = RangeError.checkValidRange(start, end, buffer.length);
    for (var offset = start; offset < limit;) {
      final last = math.min(offset + AndroidDownloadFile.chunkSize, limit);
      final bytes = Uint8List.fromList(buffer.sublist(offset, last));
      final written = await file.access<int>('write', {
        'offset': _position,
        'data': bytes,
      });
      if (written != bytes.length) {
        throw FileSystemException('下载文件未能完整写入', path);
      }
      offset = last;
      _position += bytes.length;
    }
    return this;
  });

  @override
  Future<RandomAccessFile> writeByte(int value) => writeFrom([value & 0xff]);

  @override
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) => writeFrom(encoding.encode(string));

  @override
  Future<int> position() => _run(() async => _position);

  @override
  Future<RandomAccessFile> setPosition(int position) => _run(() async {
    _position = RangeError.checkNotNegative(position, 'position');
    return this;
  });

  @override
  Future<int> length() => _run(file.length);

  @override
  Future<RandomAccessFile> truncate(int length) => _run(() async {
    _requireWritable();
    RangeError.checkNotNegative(length, 'length');
    await file.access<void>('truncate', {'length': length});
    return this;
  });

  @override
  Future<RandomAccessFile> flush() => _run(() async {
    await file.access<void>('flush');
    return this;
  });

  @override
  Future<void> close() => _run(() async {
    // The manager releases the lease after native writers and readers stop.
    _closed = true;
  });

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unsupported download-handle operation');
}
