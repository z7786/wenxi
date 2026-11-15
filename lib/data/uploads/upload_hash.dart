import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../http.dart';
import 'upload_concurrency.dart';

/// Whole-file, fixed-size part and prefix digests from one bounded stream.
class UploadHashPlan {
  UploadHashPlan({
    required this.size,
    this.whole = const [],
    this.partAlgorithm,
    this.partSize = 0,
    this.prefixAlgorithm,
    this.prefixSize = 0,
  }) {
    require(size >= 0, '文件校验范围无效');
    for (final name in [...whole, ?partAlgorithm, ?prefixAlgorithm]) {
      _algorithm(name);
    }
    require(partAlgorithm == null || partSize > 0, '文件校验分片大小无效');
    require(prefixAlgorithm == null || prefixSize >= 0, '文件校验范围无效');
  }
  final int size, partSize, prefixSize;
  final List<String> whole;
  final String? partAlgorithm, prefixAlgorithm;
}

class UploadHashResult {
  const UploadHashResult(this.whole, this.parts, this.prefix);
  final Map<String, String> whole;
  final List<String> parts;
  final String? prefix;
}

Hash _algorithm(String name) => switch (name) {
  'md5' => md5,
  'sha1' => sha1,
  'sha256' => sha256,
  _ => throw const AppException('文件校验算法不支持'),
};

/// File/provider reads stay in the caller so document permissions and guards
/// remain valid. At most 512 KiB is handed to a worker before its acknowledgement.
Future<UploadHashResult> hashUploadStream(
  Stream<List<int>> stream,
  UploadHashPlan plan, {
  void Function(int bytes)? onProgress,
}) async {
  RequestScope.checkpoint();
  if (plan.size <= 256 * 1024) {
    final accumulator = _UploadHashAccumulator(plan);
    await for (final chunk in stream) {
      RequestScope.checkpoint();
      accumulator.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      onProgress?.call(accumulator.read);
    }
    RequestScope.checkpoint();
    return accumulator.finish();
  }
  return uploadHashWorkers.run(() async {
    final port = ReceivePort();
    final replies = StreamIterator<Object?>(port);
    Isolate? worker;
    Future<Object?> reply() async {
      require(
        await RequestScope.cancellable(replies.moveNext()),
        '文件校验线程已停止，请重新选择文件',
      );
      final value = replies.current;
      require(value != null && value is! List, '文件校验线程已停止，请重新选择文件');
      return value;
    }

    try {
      worker = await Isolate.spawn(
        _hashWorker,
        (port.sendPort, plan),
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'upload-hash',
      );
      final input = await reply();
      require(input is SendPort, '文件校验线程无法启动');
      final sender = input as SendPort;
      final buffer = BytesBuilder(copy: false);
      var read = 0;
      Future<void> flush() async {
        if (buffer.isEmpty) return;
        final bytes = buffer.takeBytes();
        sender.send(TransferableTypedData.fromList([bytes]));
        final processed = await reply();
        read += bytes.length;
        require(processed == read, '本地文件校验不完整，请重新选择');
        onProgress?.call(read);
      }

      await for (final chunk in stream) {
        RequestScope.checkpoint();
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        for (var offset = 0; offset < bytes.length;) {
          final end = math.min(
            bytes.length,
            offset + 512 * 1024 - buffer.length,
          );
          buffer.add(Uint8List.sublistView(bytes, offset, end));
          offset = end;
          if (buffer.length == 512 * 1024) await flush();
        }
      }
      await flush();
      RequestScope.checkpoint();
      sender.send('finish');
      final result = await reply();
      require(result is UploadHashResult, '本地文件校验不完整，请重新选择');
      return result as UploadHashResult;
    } finally {
      worker?.kill(priority: Isolate.immediate);
      await replies.cancel();
      port.close();
    }
  });
}

void _hashWorker((SendPort, UploadHashPlan) message) {
  final (output, plan) = message;
  final accumulator = _UploadHashAccumulator(plan), input = ReceivePort();
  output.send(input.sendPort);
  input.listen((message) {
    if (message is TransferableTypedData) {
      accumulator.add(message.materialize().asUint8List());
      output.send(accumulator.read);
    } else if (message == 'finish') {
      output.send(accumulator.finish());
      input.close();
    }
  });
}

class _DigestOutput implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _UploadHashAccumulator {
  _UploadHashAccumulator(this.plan) {
    for (final name in plan.whole.toSet()) {
      final result = _whole[name] = _DigestOutput();
      _inputs.add(_algorithm(name).startChunkedConversion(result));
    }
    if (plan.prefixAlgorithm != null) {
      _prefix = _algorithm(
        plan.prefixAlgorithm!,
      ).startChunkedConversion(_prefixOutput);
    }
    if (plan.partAlgorithm != null) _newPart();
  }
  final UploadHashPlan plan;
  final _whole = <String, _DigestOutput>{};
  final _inputs = <ByteConversionSink>[];
  final _parts = <String>[];
  final _prefixOutput = _DigestOutput();
  _DigestOutput? _partOutput;
  ByteConversionSink? _part, _prefix;
  int read = 0, _partRead = 0;

  void _newPart() {
    _partRead = 0;
    _partOutput = _DigestOutput();
    _part = _algorithm(
      plan.partAlgorithm!,
    ).startChunkedConversion(_partOutput!);
  }

  void add(Uint8List bytes) {
    require(read + bytes.length <= plan.size, '本地文件内容已变化，请重新选择');
    for (final input in _inputs) {
      input.add(bytes);
    }
    final prefixLeft = math.min(plan.size, plan.prefixSize) - read;
    if (_prefix != null && prefixLeft > 0) {
      _prefix!.add(
        Uint8List.sublistView(bytes, 0, math.min(bytes.length, prefixLeft)),
      );
    }
    if (plan.partAlgorithm != null) {
      for (var offset = 0; offset < bytes.length;) {
        final length = math.min(
          bytes.length - offset,
          plan.partSize - _partRead,
        );
        _part!.add(Uint8List.sublistView(bytes, offset, offset + length));
        _partRead += length;
        offset += length;
        if (_partRead == plan.partSize) {
          _part!.close();
          _parts.add(_partOutput!.value.toString());
          _part = null;
          if (read + offset < plan.size) _newPart();
        }
      }
    }
    read += bytes.length;
  }

  UploadHashResult finish() {
    require(read == plan.size, '本地文件读取不完整，请重新选择');
    for (final input in _inputs) {
      input.close();
    }
    _prefix?.close();
    if (_part != null) {
      _part!.close();
      _parts.add(_partOutput!.value.toString());
    }
    return UploadHashResult(
      {
        for (final entry in _whole.entries)
          entry.key: entry.value.value.toString(),
      },
      _parts,
      _prefixOutput.value?.toString(),
    );
  }
}
