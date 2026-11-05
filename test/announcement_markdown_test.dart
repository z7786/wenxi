import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/announcement_markdown.dart';
import 'package:asterlink/domain/announcements.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/announcement_markdown.dart';
import 'package:asterlink/ui/announcements_page.dart';
import 'package:asterlink/ui/remote_control_dialogs.dart';

final richContent =
    '''
## 这次更新了什么

**更清楚的消息**，*更顺畅的阅读*，~~过期说明~~。

1. 查看完整公告
2. 点击链接打开项目

### 使用提示

- 手机和电脑均可阅读
- 正文可选择并复制

> 遇到问题时，请附上设备信息和脱敏日志。

---

| 功能 | 状态 |
| --- | --- |
| 消息公告 | 正常 |
| 一个较长的功能名称，用来验证小屏表格 | 支持横向查看 |

FENCEtext
configuration-example-with-a-deliberately-long-line-to-check-horizontal-scrolling-rather-than-overflow
FENCE

[问题反馈](https://github.com/z7786/wenxi/issues)
'''
        .replaceAll('FENCE', String.fromCharCodes(List.filled(3, 96)));

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.bytes);
  @override
  final int statusCode;
  final List<int> bytes;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final _Response response;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageClient implements HttpClient {
  _ImageClient(this.response);
  final _Response response;
  final requested = <Uri>[];
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requested.add(uri);
    return _Request(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  var systemFont = false;
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
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('AnnouncementFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
    final codeFont = File('C:/Windows/Fonts/consola.ttf');
    if (await codeFont.exists()) {
      await (FontLoader('monospace')..addFont(
            Future.value(ByteData.sublistView(await codeFont.readAsBytes())),
          ))
          .load();
    }
  });

  Future<void> render(
    WidgetTester tester,
    String content, {
    Size size = const Size(393, 852),
    double scale = 1,
    bool dark = false,
    RemoteLinkLauncher? launcher,
    Uri? buttonUrl,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('markdown-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme:
              appTheme(
                dark ? Brightness.dark : Brightness.light,
                fontFamily: systemFont ? 'AnnouncementFixture' : null,
              ).copyWith(
                platform: size.width > 800
                    ? TargetPlatform.windows
                    : TargetPlatform.android,
              ),
          home: AnnouncementDetailPage(
            AnnouncementMessage(
              title: '消息公告支持丰富排版',
              content: content,
              publishedAt: DateTime.utc(2026, 10, 10),
              pinned: true,
              buttonText: buttonUrl == null ? '' : '打开微信小程序',
              buttonUrl: buttonUrl,
            ),
            linkLauncher: launcher,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'List excerpts remove formatting and link targets but retain readable text',
    () {
      final text = announcementExcerpt(
        '## 更新说明\n\n**更快**，*更好*。\n\n'
        '- 下载\n- 上传\n\n'
        '[查看项目](https://github.com/z7786/wenxi)\n\n'
        '![界面截图](https://example.test/image.png)',
      );
      expect(text, '更新说明 更快，更好。 下载 上传 查看项目 界面截图');
      expect(announcementExcerpt('第一行\n第二行'), '第一行 第二行');
      expect(announcementExcerpt('---'), '点击查看公告内容');
      expect(announcementExcerpt('A &amp; B'), 'A & B');
    },
  );

  testWidgets('Plain text line breaks survive and Markdown stays selectable', (
    tester,
  ) async {
    await render(tester, '第一行\n第二行\n\n第三行');
    expect(find.text('第一行\n第二行'), findsOneWidget);
    expect(find.text('第三行'), findsOneWidget);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectable,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Inline HTTPS links require a tap and reject other schemes', (
    tester,
  ) async {
    final opened = <Uri>[];
    await render(
      tester,
      '[问题反馈](https://github.com/z7786/wenxi/issues)\n\n[无效地址](file:///C:/secret)',
      launcher: (url) async {
        opened.add(url);
        return true;
      },
    );
    expect(opened, isEmpty);
    await tester.tap(find.text('问题反馈'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://github.com/z7786/wenxi/issues')]);
    await tester.tap(find.text('无效地址'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(find.text('公告链接仅支持有效的 HTTPS 地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mini-program button dispatches only when tapped', (
    tester,
  ) async {
    final opened = <Uri>[];
    final target = Uri.parse('weixin://dl/business/?t=example-ticket');
    await render(
      tester,
      '点击下方按钮进入活动小程序。',
      buttonUrl: target,
      launcher: (url) async {
        opened.add(url);
        return true;
      },
    );
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const Key('announcement-detail-link')));
    await tester.pumpAndSettle();
    expect(opened, [target]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Raw HTML and local or embedded image URLs never load a resource',
    (tester) async {
      await render(tester, '''
<img src="https://example.test/raw.png" onerror="alert(1)">

![本机图片](file:///C:/private.png)

![资源图片](assets/icons/secret.png)

![内嵌图片](data:image/png;base64,a)
''');
      expect(find.byType(Image), findsNothing);
      expect(find.text('仅支持 HTTPS 图片'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  for (final status in [200, 404]) {
    testWidgets(
      'HTTPS image status $status is bounded and has a usable fallback',
      (tester) async {
        final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        );
        final client = _ImageClient(_Response(status, png));
        debugNetworkImageHttpClientProvider = () => client;
        addTearDown(() {
          debugNetworkImageHttpClientProvider = null;
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        });
        try {
          await render(
            tester,
            '![界面截图](https://images.example.test/$status.png)',
            buttonUrl: Uri.parse('weixin://dl/business/?t=example-ticket'),
          );
          for (var i = 0; i < 40; i++) {
            final loaded = status == 200
                ? find
                      .byType(RawImage)
                      .evaluate()
                      .any((e) => (e.widget as RawImage).image != null)
                : find.text('图片暂时无法加载').evaluate().isNotEmpty;
            if (loaded) break;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
          }
          expect(client.requested, [
            Uri.parse('https://images.example.test/$status.png'),
          ]);
          if (status == 200) {
            expect(
              tester.widget<RawImage>(find.byType(RawImage)).image,
              isNotNull,
            );
            final size = tester.getSize(find.byType(Image));
            expect(size.width, lessThanOrEqualTo(345));
            expect(size.height, lessThanOrEqualTo(420));
          } else {
            expect(find.text('图片暂时无法加载'), findsOneWidget);
            expect(find.text('界面截图'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          if (status == 200 &&
              const bool.fromEnvironment('ANNOUNCEMENT_CAPTURE_PREVIEWS')) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('markdown-capture')),
            );
            await tester.runAsync(() async {
              final picture = await boundary.toImage(pixelRatio: 1);
              final data = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '.local/announcements-review/image-mini-program.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(data!.buffer.asUint8List());
              picture.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugNetworkImageHttpClientProvider = null;
        }
      },
    );
  }

  for (final (name, size, dark, scale) in [
    ('markdown-phone', const Size(393, 852), false, 1.0),
    ('markdown-dark', const Size(393, 852), true, 1.0),
    ('markdown-large-text', const Size(320, 700), false, 1.8),
    ('markdown-windows', const Size(1100, 900), false, 1.0),
  ]) {
    testWidgets('$name supports formatted content, long code and wide tables', (
      tester,
    ) async {
      await render(tester, richContent, size: size, dark: dark, scale: scale);
      expect(find.byType(AnnouncementMarkdown), findsOneWidget);
      expect(find.text('这次更新了什么'), findsOneWidget);
      expect(find.text('使用提示'), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('ANNOUNCEMENT_CAPTURE_PREVIEWS')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('markdown-capture')),
        );
        await tester.runAsync(() async {
          final picture = await boundary.toImage(pixelRatio: 1);
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          final file = File('.local/announcements-review/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          picture.dispose();
        });
      }
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -1200),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
