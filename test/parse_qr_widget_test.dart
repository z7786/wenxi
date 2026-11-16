import 'dart:async';
import 'dart:io';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'qr_image_support.dart';
import 'support.dart';

class _QrPicker extends FileSelectorPlatform {
  XFile? file;
  Completer<XFile?>? pending;
  int opens = 0;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    opens++;
    return pending == null ? file : pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const share = '分享视频 https://pan.quark.cn/s/Qrshare 提取码：a123';
  const original = 'https://pan.baidu.com/s/1old?pwd=old1';
  late AppServices services;
  late GlobalKey<ParsePageState> page;
  late _QrPicker picker;
  final cleanup = <Future<void> Function(WidgetTester)>[];

  void scenario(
    String name,
    Future<void> Function(WidgetTester) body, {
    TargetPlatform platform = TargetPlatform.android,
  }) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final action in cleanup.reversed) {
          await action(tester);
        }
        cleanup.clear();
      }
    }, variant: TargetPlatformVariant.only(platform));
  }

  Future<void> settle(WidgetTester tester, {int cycles = 10}) async {
    for (var i = 0; i < cycles; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> render(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
    Size size = const Size(430, 960),
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    final previous = FileSelectorPlatform.instance;
    picker = _QrPicker();
    FileSelectorPlatform.instance = picker;
    services = AppServices(
      store: StateStore.memory(),
      dataDirectory: Directory('parse-qr-fixture'),
      cacheDirectory: Directory('parse-qr-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('parse-qr-fixture/files')),
      http: FakeHttp(),
      controlEnabled: false,
      platformFeatures: false,
    );
    page = GlobalKey<ParsePageState>();
    cleanup.add((tester) async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      services.close().then((_) => closed = true);
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue);
      FileSelectorPlatform.instance = previous;
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light).copyWith(platform: platform),
        home: Scaffold(body: ParsePage(services, key: page)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chooseImage(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('parse-qr')));
    await tester.pump();
    if (canScanQrForTest()) {
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const Key('parse-qr-image')));
      await tester.pump();
    }
    await settle(tester);
  }

  scenario(
    'phone image recognition fills share and code without starting parsing',
    (tester) async {
      await render(tester);
      picker.file = XFile.fromData(
        (await tester.runAsync(() => qrImageFixture([share])))!,
      );
      await chooseImage(tester);
      expect(page.currentState!.input.text, share);
      expect(page.currentState!.code.text, 'a123');
      expect(page.currentState!.current!.platform!.key, 'Quark');
      expect(page.currentState!.working, isFalse);
      expect(picker.opens, 1);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'iOS selects a screenshot from Photos and fills the parser',
    (tester) async {
      await render(tester, platform: TargetPlatform.iOS);
      final bytes = (await tester.runAsync(() => qrImageFixture([share])))!;
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        (call) async {
          calls.add(call.method);
          return bytes;
        },
      );
      await chooseImage(tester);
      expect(page.currentState!.input.text, share);
      expect(page.currentState!.code.text, 'a123');
      expect(calls, ['pickQrImage']);
      expect(picker.opens, 0);
      expect(tester.takeException(), isNull);
    },
    platform: TargetPlatform.iOS,
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    scenario(
      '$platform camera fills cloud commands and cancellation preserves input',
      (tester) async {
        await render(tester, platform: platform);
        page.currentState!.acceptClipboard(original);
        final calls = <String>[];
        String? reply = '/*391R8TRNLu2U:/';
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          nativeChannel,
          (call) async {
            calls.add(call.method);
            return reply;
          },
        );
        Future<void> scan() async {
          await tester.tap(find.byKey(const Key('parse-qr')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.byKey(const Key('parse-qr-camera')));
          await settle(tester);
        }

        await scan();
        expect(page.currentState!.input.text, reply);
        reply = null;
        await scan();
        expect(page.currentState!.input.text, '/*391R8TRNLu2U:/');
        expect(calls, ['scanQr', 'scanQr']);
        expect(tester.takeException(), isNull);
      },
      platform: platform,
    );
  }

  scenario(
    'desktop recognizes image and lets user choose among multiple codes',
    (tester) async {
      await render(
        tester,
        platform: TargetPlatform.windows,
        size: const Size(1050, 900),
      );
      picker.file = XFile.fromData(
        (await tester.runAsync(() => qrImageFixture([share, original])))!,
      );
      await chooseImage(tester);
      expect(find.text('选择要填入的二维码内容'), findsOneWidget);
      expect(page.currentState!.input.text, isEmpty);
      await tester.tap(find.text(original));
      await tester.pumpAndSettle();
      expect(page.currentState!.input.text, original);
      expect(page.currentState!.code.text, 'old1');
      expect(find.byKey(const Key('parse-qr-camera')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    platform: TargetPlatform.windows,
  );

  scenario(
    'cancelled or unreadable images preserve input and show a useful error',
    (tester) async {
      await render(tester, platform: TargetPlatform.windows);
      page.currentState!.acceptClipboard(original);
      await chooseImage(tester);
      expect(page.currentState!.input.text, original);
      picker.file = XFile.fromData(Uint8List.fromList([1, 2, 3]));
      await chooseImage(tester);
      expect(page.currentState!.input.text, original);
      expect(find.textContaining('无法读取这张图片'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    platform: TargetPlatform.windows,
  );

  scenario(
    'pending image cannot overwrite user edits or open a second picker',
    (tester) async {
      await render(tester, platform: TargetPlatform.windows);
      picker.pending = Completer<XFile?>();
      page.currentState!.acceptClipboard(original);
      await tester.tap(find.byKey(const Key('parse-qr')));
      await tester.pump();
      final button = tester.widget<TextButton>(
        find.byKey(const Key('parse-qr')),
      );
      expect(button.onPressed, isNull);
      await tester.enterText(find.byKey(const Key('parse-input')), share);
      picker.pending!.complete(
        XFile.fromData(
          (await tester.runAsync(() => qrImageFixture([original])))!,
        ),
      );
      await settle(tester);
      expect(page.currentState!.input.text, share);
      expect(picker.opens, 1);
      expect(tester.takeException(), isNull);
    },
    platform: TargetPlatform.windows,
  );

  scenario('late image after page disposal is ignored', (tester) async {
    await render(tester, platform: TargetPlatform.windows);
    picker.pending = Completer<XFile?>();
    await tester.tap(find.byKey(const Key('parse-qr')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    picker.pending!.complete(null);
    await settle(tester);
    expect(tester.takeException(), isNull);
  }, platform: TargetPlatform.windows);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    scenario('$platform narrow large-text QR entry stays accessible', (
      tester,
    ) async {
      await render(
        tester,
        platform: platform,
        size: const Size(320, 760),
        scale: 1.8,
      );
      expect(find.byKey(const Key('parse-qr')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await chooseImage(tester);
      expect(picker.opens, 1);
      expect(tester.takeException(), isNull);
    }, platform: platform);
  }
}

bool canScanQrForTest() =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;
