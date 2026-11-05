import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Each instance is confined to one isolate. No Dart callbacks enter QuickJS.
class SourceJsBridge {
  SourceJsBridge({String? libraryPath}) {
    final override =
        libraryPath ?? Platform.environment['ASTERLINK_JS_LIBRARY'];
    final library = override != null
        ? DynamicLibrary.open(override)
        : Platform.isMacOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open(
            Platform.isWindows ? 'asterlink_js.dll' : 'libasterlink_js.so',
          );
    _new = library
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'al_js_new',
        );
    _begin = library
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Utf8>),
          int Function(Pointer<Void>, Pointer<Utf8>)
        >('al_js_begin');
    _poll = library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('al_js_poll');
    _reply = library
        .lookupFunction<
          Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>, Int32),
          int Function(Pointer<Void>, int, Pointer<Utf8>, int)
        >('al_js_reply');
    _free = library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('al_js_free_text');
    _close = library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('al_js_close');
    _handle = _new();
    if (_handle == nullptr) throw StateError('SCRIPT_UNAVAILABLE');
  }
  late final Pointer<Void> Function() _new;
  late final int Function(Pointer<Void>, Pointer<Utf8>) _begin;
  late final Pointer<Utf8> Function(Pointer<Void>) _poll;
  late final int Function(Pointer<Void>, int, Pointer<Utf8>, int) _reply;
  late final void Function(Pointer<Utf8>) _free;
  late final void Function(Pointer<Void>) _close;
  late Pointer<Void> _handle;
  void start(Map<String, dynamic> packet) {
    final text = jsonEncode(packet).toNativeUtf8();
    try {
      _begin(_handle, text);
    } finally {
      calloc.free(text);
    }
  }

  Map<String, dynamic> poll() {
    final text = _poll(_handle);
    if (text == nullptr) throw StateError('SCRIPT_MEMORY');
    try {
      return (jsonDecode(text.toDartString()) as Map).cast<String, dynamic>();
    } finally {
      _free(text);
    }
  }

  void reply(int id, Object? value, {bool failed = false}) {
    final text = jsonEncode(value).toNativeUtf8();
    try {
      _reply(_handle, id, text, failed ? 1 : 0);
    } finally {
      calloc.free(text);
    }
  }

  void close() {
    if (_handle == nullptr) return;
    _close(_handle);
    _handle = nullptr;
  }
}
