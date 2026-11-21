import 'dart:ui' as ui;
import 'package:asterlink/platform/windows_clipboard_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ui.KeyData key(
  int logical,
  ui.KeyEventType type, {
  bool synthesized = false,
  int? physical,
}) => ui.KeyData(
  timeStamp: const Duration(milliseconds: 12),
  type: type,
  physical: physical ?? WindowsClipboardKeys.unknownPhysical,
  logical: logical,
  character:
      type == ui.KeyEventType.down && logical == WindowsClipboardKeys.vLogical
      ? 'v'
      : null,
  synthesized: synthesized,
);

List<ui.KeyData> historyPaste() => [
  key(WindowsClipboardKeys.controlLogical, ui.KeyEventType.down),
  key(
    WindowsClipboardKeys.controlLogical,
    ui.KeyEventType.up,
    synthesized: true,
  ),
  key(WindowsClipboardKeys.vLogical, ui.KeyEventType.down),
  key(WindowsClipboardKeys.vLogical, ui.KeyEventType.up),
  key(
    WindowsClipboardKeys.controlLogical,
    ui.KeyEventType.down,
    synthesized: true,
  ),
  key(
    WindowsClipboardKeys.controlLogical,
    ui.KeyEventType.up,
    synthesized: true,
  ),
];

void main() {
  test('history paste repairs only the scan-code-zero sequence', () {
    final repair = WindowsClipboardKeys();
    final events = historyPaste().expand(repair.rewrite).toList();
    expect(events.map((event) => event.physical), [
      0x700e0,
      0x70019,
      0x70019,
      0x700e0,
    ]);
    expect(events.map((event) => event.type), [
      ui.KeyEventType.down,
      ui.KeyEventType.down,
      ui.KeyEventType.up,
      ui.KeyEventType.up,
    ]);
    expect(repair.pending, isFalse);
    expect(
      events.every((event) => event.timeStamp.inMilliseconds == 12),
      isTrue,
    );
  });

  test('zero transit probe and ordinary Ctrl V are forwarded unchanged', () {
    final repair = WindowsClipboardKeys();
    final probe = key(0, ui.KeyEventType.down, physical: 0);
    expect(repair.rewrite(probe).single, same(probe));
    for (final data in [
      key(
        WindowsClipboardKeys.controlLogical,
        ui.KeyEventType.down,
        physical: 0x700e0,
      ),
      key(
        WindowsClipboardKeys.vLogical,
        ui.KeyEventType.down,
        physical: 0x70019,
      ),
      key(WindowsClipboardKeys.vLogical, ui.KeyEventType.up, physical: 0x70019),
      key(
        WindowsClipboardKeys.controlLogical,
        ui.KeyEventType.up,
        physical: 0x700e0,
      ),
    ]) {
      expect(repair.rewrite(data).single, same(data));
    }
    repair.rewrite(historyPaste().first);
    expect(repair.rewrite(probe).single, same(probe));
    expect(repair.pending, isTrue);
  });

  test(
    'unrelated synthetic events and already held physical keys are preserved',
    () {
      final repair = WindowsClipboardKeys();
      final correction = key(
        WindowsClipboardKeys.controlLogical,
        ui.KeyEventType.down,
        synthesized: true,
      );
      expect(repair.rewrite(correction).single, same(correction));
      final heldV = key(
        WindowsClipboardKeys.vLogical,
        ui.KeyEventType.down,
        physical: 0x70019,
      );
      expect(repair.rewrite(heldV).single, same(heldV));
      final ctrl = historyPaste().first;
      expect(repair.rewrite(ctrl).single, same(ctrl));
      expect(repair.pending, isFalse);
    },
  );

  test(
    'interruption releases injected modifiers without swallowing typing',
    () {
      final repair = WindowsClipboardKeys();
      for (final data in historyPaste().take(3)) {
        repair.rewrite(data);
      }
      final a = key(0x61, ui.KeyEventType.down, physical: 0x70004);
      final events = repair.rewrite(a);
      expect(events.map((event) => event.physical), [
        0x70019,
        0x700e0,
        0x70004,
      ]);
      expect(events.last, same(a));
      expect(repair.pending, isFalse);
      for (final data in historyPaste().skip(3)) {
        expect(repair.rewrite(data), isEmpty);
      }
    },
  );

  test('timeout and a simple injected Ctrl release leave no stuck key', () {
    final repair = WindowsClipboardKeys();
    repair.rewrite(historyPaste().first);
    final releases = repair.release();
    expect(releases.single.physical, 0x700e0);
    expect(releases.single.synthesized, isTrue);
    expect(repair.release(), isEmpty);
    repair.rewrite(historyPaste().first);
    expect(
      repair
          .rewrite(key(WindowsClipboardKeys.controlLogical, ui.KeyEventType.up))
          .single
          .physical,
      0x700e0,
    );
    expect(repair.pending, isFalse);
  });

  testWidgets(
    'repaired history paste replaces selection once then accepts typing',
    (tester) async {
      final controller = TextEditingController(text: 'abcDEFghi');
      addTearDown(controller.dispose);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': '链接'};
          if (call.method == 'Clipboard.hasStrings') return {'value': true};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TextField(controller: controller)),
        ),
      );
      await tester.tap(find.byType(TextField));
      controller.selection = const TextSelection(
        baseOffset: 3,
        extentOffset: 6,
      );
      await tester.pump();
      final repair = WindowsClipboardKeys();
      for (final data in historyPaste().expand(repair.rewrite)) {
        final logical = LogicalKeyboardKey.findKeyByKeyId(data.logical)!;
        final physical = PhysicalKeyboardKey.findKeyByCode(data.physical)!;
        if (data.type == ui.KeyEventType.down) {
          await tester.sendKeyDownEvent(
            logical,
            physicalKey: physical,
            platform: 'windows',
          );
        } else {
          await tester.sendKeyUpEvent(
            logical,
            physicalKey: physical,
            platform: 'windows',
          );
        }
        await tester.pump();
      }
      expect(controller.text, 'abc链接ghi');
      expect(HardwareKeyboard.instance.isControlPressed, isFalse);
      tester.testTextInput.enterText('${controller.text}!');
      await tester.pump();
      expect(controller.text, 'abc链接ghi!');
      expect(tester.takeException(), isNull);
    },
  );
}
