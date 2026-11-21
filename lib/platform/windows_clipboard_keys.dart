import 'dart:async';
import 'dart:io';
import 'dart:ui';

/// Windows clipboard history sends scan-code-zero Ctrl/V events. Flutter gives
/// them the same physical key and inserts modifier releases between them:
/// https://github.com/flutter/flutter/issues/143997
class WindowsClipboardKeys {
  static const unknownPhysical = 0x1600000000;
  static const controlPhysical = 0x700e0;
  static const vPhysical = 0x70019;
  static const controlLogical = 0x200000100;
  static const vLogical = 0x76;

  int _stage = 0;
  bool _control = false, _v = false, _realControl = false, _realV = false;
  bool _ignoreTrailing = false;
  KeyData? _last;

  bool get pending => _control || _v;

  KeyData _key(KeyData source, int physical) => KeyData(
    timeStamp: source.timeStamp,
    type: source.type,
    physical: physical,
    logical: source.logical,
    character: source.character,
    synthesized: source.synthesized,
    deviceType: source.deviceType,
  );

  List<KeyData> release() {
    if (_stage != 0) _ignoreTrailing = true;
    final source = _last;
    final result = <KeyData>[];
    if (source != null) {
      for (final (pressed, physical, logical) in [
        (_v, vPhysical, vLogical),
        (_control, controlPhysical, controlLogical),
      ]) {
        if (pressed) {
          result.add(
            KeyData(
              timeStamp: source.timeStamp,
              type: KeyEventType.up,
              physical: physical,
              logical: logical,
              character: null,
              synthesized: true,
              deviceType: source.deviceType,
            ),
          );
        }
      }
    }
    _stage = 0;
    _control = _v = false;
    return result;
  }

  List<KeyData> rewrite(KeyData data) {
    // This is Flutter's keyboard transit-mode probe, not an input event. It
    // must always reach the binding, including during a repaired sequence.
    if (data.physical == 0 && data.logical == 0) return [data];
    _last = data;
    final junk = data.physical == unknownPhysical;
    final ctrl = junk && data.logical == controlLogical;
    final v = junk && data.logical == vLogical;
    final down = data.type == KeyEventType.down;
    final up = data.type == KeyEventType.up;
    if ((ctrl || v) && down && !data.synthesized && _stage == 0) {
      _ignoreTrailing = false;
    }
    if (_stage == 0 &&
        ctrl &&
        down &&
        !data.synthesized &&
        !_realControl &&
        !_realV) {
      _stage = 1;
      _ignoreTrailing = false;
      _control = true;
      return [_key(data, controlPhysical)];
    }
    if (_stage == 1 && ctrl && up && data.synthesized) {
      _stage = 2;
      return [];
    }
    if (ctrl && up && !data.synthesized && _control) {
      return release();
    }
    if (_stage == 2 && v && down && !data.synthesized) {
      _stage = 3;
      _v = true;
      return [_key(data, vPhysical)];
    }
    if (_stage == 3 && v && up && !data.synthesized) {
      _stage = 4;
      _v = false;
      return [_key(data, vPhysical)];
    }
    if (_stage == 4 && ctrl && down && data.synthesized) {
      _stage = 5;
      return [];
    }
    if (_stage == 5 && ctrl && up && data.synthesized) {
      _stage = 0;
      _control = false;
      return [_key(data, controlPhysical)];
    }
    final releases = release();
    if (data.physical == controlPhysical) _realControl = !up;
    if (data.physical == vPhysical) _realV = !up;
    // A trailing synthetic modifier correction can arrive after a timeout or
    // interrupted sequence. It no longer has a corresponding pressed key.
    if (_ignoreTrailing && ((ctrl && (data.synthesized || up)) || (v && up))) {
      return releases;
    }
    return [...releases, data];
  }
}

bool _installed = false;

void installWindowsClipboardKeys() {
  if (!Platform.isWindows || _installed) return;
  final dispatcher = PlatformDispatcher.instance;
  final original = dispatcher.onKeyData;
  if (original == null) return;
  _installed = true;
  final repair = WindowsClipboardKeys();
  Timer? releaseTimer;
  dispatcher.onKeyData = (data) {
    final events = repair.rewrite(data);
    releaseTimer?.cancel();
    if (repair.pending) {
      releaseTimer = Timer(const Duration(seconds: 1), () {
        for (final event in repair.release()) {
          original(event);
        }
      });
    }
    var handled = events.isEmpty;
    for (final event in events) {
      handled = original(event) || handled;
    }
    return handled;
  };
}
