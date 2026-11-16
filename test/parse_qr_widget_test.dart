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
import 'package:asterlink/ui/cloud_favorites_page.dart';
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
    double pixelRatio = 1,
  }) async {
    tester.view.devicePixelRatio = pixelRatio;
    tester.view.physicalSize = size * pixelRatio;
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

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final (width, scale, pixelRatio) in [
      (360.0, 1.0, 3.0),
      (393.0, 1.8, 2.75),
      (320.0, 2.0, 2.0),
    ]) {
      scenario(
        '$platform mobile header keeps tools beside the title at $width / $scale',
        (tester) async {
          await render(
            tester,
            platform: platform,
            size: Size(width, 960),
            scale: scale,
            pixelRatio: pixelRatio,
          );
          void expectHeaderAlignment() {
            final paste = tester.getRect(find.byKey(const Key('parse-paste')));
            final qr = tester.getRect(find.byKey(const Key('parse-qr')));
            final history = tester.getRect(
              find.byKey(const Key('parse-history')),
            );
            expect(qr.center.dy, closeTo(paste.center.dy, 1));
            expect(history.center.dy, closeTo(paste.center.dy, 1));
            expect(qr.left, greaterThanOrEqualTo(paste.right));
            expect(history.left, greaterThanOrEqualTo(qr.right));
            expect(history.right, lessThanOrEqualTo(width - 38));
            expect(qr.size.shortestSide, greaterThanOrEqualTo(48 - 1e-6));
            expect(history.size.shortestSide, greaterThanOrEqualTo(48 - 1e-6));
            expect(
              find.byKey(const Key('parse-qr')).hitTestable(),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('parse-history')).hitTestable(),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          }

          expectHeaderAlignment();
          page.currentState!.acceptClipboard('$share\n$original');
          await tester.pumpAndSettle();
          expectHeaderAlignment();
          expect(page.currentState!.links, hasLength(2));
          await tester.tap(find.byKey(const Key('parse-history')));
          await tester.pumpAndSettle();
          expect(find.text('历史解析'), findsOneWidget);
          await tester.tap(find.byTooltip('关闭历史'));
          await tester.pumpAndSettle();
          await chooseImage(tester);
          expect(picker.opens, 1);
          expect(page.currentState!.input.text, '$share\n$original');
          expectHeaderAlignment();
        },
        platform: platform,
      );
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final (size, scale, twoColumns) in [
      (const Size(768, 1024), 1.0, false),
      (const Size(1280, 800), 1.0, true),
      (const Size(1280, 800), 1.8, false),
    ]) {
      scenario(
        '$platform tablet parser fills $size at text scale $scale',
        (tester) async {
          await render(tester, platform: platform, size: size, scale: scale);
          final main = tester.getRect(find.byKey(const Key('parse-tools')));
          final summaries = tester.getRect(find.byType(CloudFavoritesSummary));
          expect(main.left, closeTo(28, 1));
          expect(summaries.right, closeTo(size.width - 28, 1));
          if (twoColumns) {
            expect(main.width, greaterThan(680));
            expect(summaries.left, greaterThan(main.right));
            expect(summaries.top, closeTo(main.top, 1));
          } else {
            expect(main.width, closeTo(size.width - 56, 1));
            expect(summaries.left, closeTo(main.left, 1));
            expect(summaries.top, greaterThan(main.bottom));
          }
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('parse-input')))
                .minLines,
            6,
          );
          expect(tester.takeException(), isNull);
        },
        platform: platform,
      );
    }
    scenario(
      '$platform tablet rotation retains editor and composing text',
      (tester) async {
        await render(
          tester,
          platform: platform,
          size: const Size(1280, 800),
          pixelRatio: 2,
        );
        final inputFinder = find.byKey(const Key('parse-input'));
        await tester.showKeyboard(inputFinder);
        const draft = TextEditingValue(
          text: '分享链接和未完成的拼音',
          selection: TextSelection.collapsed(offset: 11),
          composing: TextRange(start: 5, end: 11),
        );
        tester.testTextInput.updateEditingValue(draft);
        await tester.pump();
        final editor = tester.state(
          find.descendant(of: inputFinder, matching: find.byType(EditableText)),
        );
        for (final next in [const Size(800, 1280), const Size(1280, 800)]) {
          tester.view.physicalSize = next * 2;
          await tester.pumpAndSettle();
          expect(
            tester.state(
              find.descendant(
                of: inputFinder,
                matching: find.byType(EditableText),
              ),
            ),
            same(editor),
          );
          expect(page.currentState!.focus.hasFocus, isTrue);
          expect(page.currentState!.input.value, draft);
          expect(tester.testTextInput.isVisible, isTrue);
          expect(tester.takeException(), isNull);
        }
      },
      platform: platform,
    );
  }

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
