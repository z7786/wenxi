import 'dart:ffi';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/utils/isolates.dart';

/// Call only after event consumers and video outputs have detached. Do not
/// cancel this worker: libmpv must join its native threads before releasing the
/// callback trampoline. Only send primitive data, never a Player or FFI binding.
Future<void> destroyNativePlayer(String library, int address) => compute(
      _destroy,
      (library, address),
      debugLabel: 'media_kit.dispose',
    );

void _destroy((String, int) args) {
  final mpv = generated.MPV(DynamicLibrary.open(args.$1));
  mpv.mpv_terminate_destroy(Pointer.fromAddress(args.$2));
}
