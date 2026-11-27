import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/preview_page.dart';
import 'browser_test_support.dart';

class _Files extends BrowserTestConnector {
  _Files() : super(CloudPlatform.tianyi);
  int preparations = 0;
  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async => const [
    CloudFile(id: 'video', name: 'video.mp4'),
    CloudFile(id: 'text', name: 'notes.txt'),
    CloudFile(id: 'folder', name: 'folder.mp4', isDirectory: true),
  ];
  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    preparations++;
    throw StateError('Browsing file menus must not prepare a media URL');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? font;
  setUpAll(() async {
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final systemFont = File('C:/Windows/Fonts/msyh.ttc');
    if (await systemFont.exists()) {
      await (FontLoader('FileMenuFixture')..addFont(
            Future.value(ByteData.sublistView(await systemFont.readAsBytes())),
          ))
          .load();
      font = 'FileMenuFixture';
    }
  });
  const native = MethodChannel('com.asterlink.app/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late BrowserUiFixture fixture;
  late _Files files;
  final nativeCalls = <MethodCall>[];

  Future<void> prepare() async {
    fixture = await BrowserUiFixture.create();
    files = _Files();
    fixture.services.cloud.connectors[CloudPlatform.tianyi] = files;
    nativeCalls.clear();
    await fixture.services.store.change((draft) {
      draft['defaultVideoPlayers'] = {
        'android': 'fixture.player/PlayerActivity',
        'windows': 'C:/Players/fixture.exe',
        'macos': '/Applications/Fixture.app',
      };
    });
    messenger.setMockMethodCallHandler(native, (call) async {
      nativeCalls.add(call);
      return null;
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(native, null));

  void browserTest(
    String name,
    WidgetTesterCallback body, {
    required TargetPlatformVariant variant,
  }) {
    testWidgets(name, (tester) async {
      await prepare();
      debugNetworkImageHttpClientProvider = ThumbnailHttpClient.new;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugNetworkImageHttpClientProvider = null;
        await fixture.close();
      }
    }, variant: variant);
  }

  Future<void> render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    bool dark = false,
  }) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await fixture.render(
      tester,
      size: size,
      scale: scale,
      dark: dark,
      font: font,
    );
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final platform in TargetPlatform.values) {
    browserTest(
      'File menus keep preview without default-player configuration on $platform',
      (tester) async {
        final desktop = {
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        }.contains(platform);
        await render(
          tester,
          size: desktop ? const Size(1200, 760) : const Size(320, 700),
          scale: desktop ? 1 : 1.8,
          dark: !desktop,
        );
        for (final file in ['video.mp4', 'notes.txt', 'folder.mp4']) {
          await tap(tester, find.byTooltip('$file操作'));
          expect(find.text('设置默认播放器'), findsNothing);
          expect(find.byKey(const Key('file-default-player')), findsNothing);
          if (file != 'folder.mp4') {
            expect(find.text('预览 / 文件详情'), findsOneWidget);
          }
          Navigator.pop(tester.element(find.text('收藏')));
          await tester.pumpAndSettle();
        }
        expect(find.byType(PreviewPage), findsNothing);
        expect(files.preparations, 0);
        expect(nativeCalls, isEmpty);
        expect(fixture.services.store.data['defaultVideoPlayers'], isNotEmpty);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  browserTest(
    'Windows video context menu keeps preview without a default player',
    (tester) async {
      await render(tester, size: const Size(1200, 760));
      await tester.tap(find.text('video.mp4'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('设置默认播放器'), findsNothing);
      expect(find.text('预览 / 文件详情'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.byType(PreviewPage), findsNothing);
      expect(files.preparations, 0);
      expect(nativeCalls, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
