import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:asterlink/platform/playback_device.dart';
import 'package:asterlink/platform/windows_pip.dart';

class _Window {
  static const normal = Rect.fromLTWH(-1000, 120, 900, 650);
  final calls = <MethodCall>[];
  Rect bounds = normal;
  bool fullscreen = false, maximized = false, alwaysOnTop = false;
  bool maximizable = true, visible = true, minimized = false, resizable = false;
  bool failPin = false, beforeFullMax = false;
  Size minimum = appWindowMinimumSize;
  String titleStyle = 'normal';
  bool frameless = false;
  double aspect = 0;
  Completer<void>? holdResize;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'isFullScreen':
        return fullscreen;
      case 'isMaximized':
        return maximized;
      case 'isAlwaysOnTop':
        return alwaysOnTop;
      case 'isMaximizable':
        return maximizable;
      case 'isResizable':
        return resizable;
      case 'isVisible':
        return visible;
      case 'isMinimized':
        return minimized;
      case 'getBounds':
        return {
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        };
      case 'setBounds':
        await holdResize?.future;
        bounds = Rect.fromLTWH(
          args['x'],
          args['y'],
          args['width'],
          args['height'],
        );
      case 'setMinimumSize':
        minimum = Size(args['width'], args['height']);
      case 'setAspectRatio':
        aspect = args['aspectRatio'];
      case 'setTitleBarStyle':
        titleStyle = args['titleBarStyle'];
        frameless = false;
      case 'setAsFrameless':
        frameless = true;
      case 'setMaximizable':
        maximizable = args['isMaximizable'];
      case 'setResizable':
        resizable = args['isResizable'];
      case 'setAlwaysOnTop':
        if (failPin && args['isAlwaysOnTop'] == true) {
          throw PlatformException(code: 'fake-error');
        }
        alwaysOnTop = args['isAlwaysOnTop'];
      case 'setFullScreen':
        final next = args['isFullScreen'] as bool;
        if (next && !fullscreen) beforeFullMax = maximized;
        if (!next && fullscreen) maximized = beforeFullMax;
        fullscreen = next;
      case 'unmaximize':
        maximized = false;
        bounds = normal;
      case 'maximize':
        maximized = true;
      case 'show':
        visible = true;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Window window;
  late NativePlaybackDevice device;
  setUp(() {
    window = _Window();
    messenger.setMockMethodCallHandler(channel, window.handle);
    device = NativePlaybackDevice(targetPlatform: TargetPlatform.windows);
  });
  tearDown(() async {
    await device.finish();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'Windows PiP is pinned, draggable, sized to video and fully restorable',
    () async {
      await device.start(video: true);
      await device.update(playing: true, width: 1920, height: 1080);
      expect(device.supportsPip, isTrue);
      expect(device.supportsDesktopPip, isTrue);
      expect(await device.enterPip(), isTrue);
      expect(device.inPip, isTrue);
      expect(window.alwaysOnTop, isTrue);
      expect(window.frameless, isTrue);
      expect(window.minimum, const Size(240, 135));
      expect(window.bounds.size, const Size(480, 270));
      expect(window.bounds.left, lessThan(0));
      expect(window.maximizable, isFalse);
      expect(window.resizable, isTrue);
      for (final edge in ResizeEdge.values) {
        await device.resizePip(edge);
        expect(window.calls.last.method, 'startResizing');
        expect(window.calls.last.arguments['resizeEdge'], edge.name);
      }
      await device.dragPip();
      expect(window.calls.last.method, 'startDragging');
      expect(await device.queryPip(), isTrue);
      window.minimized = true;
      expect(await device.queryPip(), isFalse);
      window.minimized = false;
      await device.exitPip();
      expect(device.inPip, isFalse);
      expect(window.bounds, _Window.normal);
      expect(window.minimum, appWindowMinimumSize);
      expect(window.alwaysOnTop, isFalse);
      expect(window.titleStyle, 'normal');
      expect(window.frameless, isFalse);
      expect(window.aspect, 0);
      expect(window.maximizable, isTrue);
      expect(window.resizable, isFalse);
    },
  );

  test(
    'Portrait PiP preserves existing pin and maximized state on finish',
    () async {
      window
        ..alwaysOnTop = true
        ..maximized = true;
      await device.start(video: true);
      await device.update(playing: true, width: 1080, height: 1920);
      await device.enterPip();
      expect(window.bounds.height, greaterThan(window.bounds.width));
      expect(window.maximized, isFalse);
      await device.finish();
      expect(window.maximized, isTrue);
      expect(window.alwaysOnTop, isTrue);
      expect(window.bounds, _Window.normal);
    },
  );

  test(
    'Player fullscreen returns after PiP and is released when playback ends',
    () async {
      window.maximized = true;
      await device.start(video: true);
      await device.fullscreen(true);
      await device.enterPip();
      expect(window.fullscreen, isFalse);
      await device.exitPip();
      expect(window.fullscreen, isTrue);
      expect(window.maximized, isTrue);
      await device.finish();
      expect(window.fullscreen, isFalse);
      expect(window.maximized, isTrue);
    },
  );

  test(
    'Partial native failure restores all flags and leaves normal playback',
    () async {
      window.failPin = true;
      await device.start(video: true);
      await expectLater(device.enterPip(), throwsA(isA<PlatformException>()));
      expect(device.inPip, isFalse);
      expect(window.bounds, _Window.normal);
      expect(window.minimum, appWindowMinimumSize);
      expect(window.titleStyle, 'normal');
      expect(window.maximizable, isTrue);
    },
  );

  test(
    'Closing while PiP entry is pending still restores the desktop',
    () async {
      window.holdResize = Completer<void>();
      await device.start(video: true);
      final entered = device.enterPip();
      for (
        var i = 0;
        i < 50 && !window.calls.any((c) => c.method == 'setBounds');
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      final finished = device.finish();
      window.holdResize!.complete();
      expect(await entered, isFalse);
      await finished;
      expect(window.bounds, _Window.normal);
      expect(window.alwaysOnTop, isFalse);
      expect(window.minimum, appWindowMinimumSize);
    },
  );

  test('Audio does not offer desktop PiP', () async {
    await device.start(video: false);
    expect(device.supportsPip, isFalse);
    expect(await device.enterPip(), isFalse);
  });
}
