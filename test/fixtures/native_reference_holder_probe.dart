import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
// Verify the debug buffer without loading libmpv or a video output.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/utils/native_reference_holder.dart';

Future<List<Pointer<Void>>> initialize() async {
  final result = Completer<List<Pointer<Void>>>();
  NativeReferenceHolder.ensureInitialized(result.complete);
  return result.future.timeout(const Duration(seconds: 5));
}

Future<void> lookup(SendPort destination) async {
  final references = await initialize();
  destination.send([
    for (final reference in references)
      [reference.address, reference.cast<Int64>().value],
  ]);
}

Future<void> main(List<String> arguments) async {
  final file = File(
    '${Directory.systemTemp.path}/com.alexmercerind.media_kit.NativeReferenceHolder.$pid',
  );
  if (arguments.single == 'stale') {
    // An address from a dead process must never be dereferenced. Keep the
    // invalid fixture in this child process so a regression cannot crash tests.
    await file.writeAsString('1');
    final references = await initialize();
    if (references.isNotEmpty) {
      throw StateError('Stale pointer reported as live');
    }
    final reference = calloc<Int64>();
    try {
      await NativeReferenceHolder.instance.add(reference);
      await NativeReferenceHolder.instance.remove(reference);
    } finally {
      calloc.free(reference);
    }
    if (await file.readAsString() != '1') {
      throw StateError('Test runner reused hot-restart storage');
    }
    stdout.writeln('stale-pointer-ignored');
    return;
  }

  if (arguments.single != 'hot-restart') throw ArgumentError('Unknown probe');
  final references = await initialize();
  if (references.isNotEmpty) throw StateError('Unexpected initial references');
  final reference = calloc<Int64>()..value = 240;
  final receiver = ReceivePort();
  try {
    await NativeReferenceHolder.instance.add(reference);
    await Isolate.spawn(lookup, receiver.sendPort);
    final discovered = await receiver.first.timeout(const Duration(seconds: 5));
    if (discovered is! List ||
        discovered.length != 1 ||
        discovered[0][0] != reference.address ||
        discovered[0][1] != 240) {
      throw StateError(
        'Live process buffer did not survive an isolate restart',
      );
    }
    await NativeReferenceHolder.instance.remove(reference);
    stdout.writeln('hot-restart-preserved');
  } finally {
    receiver.close();
    calloc.free(reference);
  }
}
