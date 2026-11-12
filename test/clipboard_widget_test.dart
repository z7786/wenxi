import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/clipboard_link_banner.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'support.dart';

class _ClipboardShare extends CloudConnector {
  @override
  CloudPlatform get platform => CloudPlatform.uc;
  final opened = <ParsedLink>[];
  int lists = 0;
  Future<void>? barrier;

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    opened.add(link);
    await barrier;
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '剪贴板分享',
      rootId: 'root',
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    lists++;
    return const [CloudFile(id: 'file', name: '分享文件.zip', size: 123)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late FakeHttp http;
  late _ClipboardShare connector;
  String? clipboard;
  int reads = 0;

  setUp(() {
    clipboard = null;
    reads = 0;
  });

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        services.close().then((_) => closed = true);
        for (var i = 0; i < 30 && !closed; i++) {
          await tester.pump();
        }
        expect(closed, isTrue);
        services.store.dispose();
      }
    });
  }

  Future<void> render(
    WidgetTester tester, {
    int tab = 0,
    bool dark = false,
  }) async {
    http = FakeHttp();
    services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'settings': {'theme': dark ? 'Dark' : 'Light'},
      }),
      dataDirectory: Directory('test-fixture'),
      cacheDirectory: Directory('test-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('test-fixture/saved')),
      http: http,
      platformFeatures: false,
      clipboardReader: () async {
        reads++;
        return clipboard;
      },
    );
    connector = _ClipboardShare();
    services.cloud.connectors[CloudPlatform.uc] = connector;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      AsterLinkApp(services, initialTab: tab == 0 ? 0 : tab + 1),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  scenario(
    'discovery preserves the draft and clicking starts parsing and opens files',
    (tester) async {
      await render(tester);
      final parse = tester.state<ParsePageState>(find.byType(ParsePage));
      parse.input.text = 'unfinished draft';
      clipboard = 'https://drive.uc.cn/s/abc123 提取码：a123';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardLinkBanner), findsOneWidget);
      expect(parse.input.text, 'unfinished draft');
      expect(http.calls, isEmpty);
      expect(connector.opened, isEmpty);
      await tester.tap(find.text('立即解析'));
      await tester.pumpAndSettle();
      expect(parse.current!.passcode, 'a123');
      expect(parse.input.text, contains('https://drive.uc.cn/s/abc123'));
      expect(find.byType(ClipboardLinkBanner), findsNothing);
      expect(connector.opened.single.shareId, 'abc123');
      expect(connector.opened.single.passcode, 'a123');
      expect(connector.lists, 1);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.text('分享文件.zip'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  scenario(
    'cross-tab clipboard parsing keeps all links and codes and enters login when needed',
    (tester) async {
      clipboard =
          'https://caiyun.139.com/m/i?Mobile123&pass=m123\n\n'
          'https://www.123684.com/s/Pan_123 提取码：p123';
      await render(tester, tab: 2);
      expect(find.byType(ClipboardLinkBanner), findsOneWidget);
      await tester.tap(find.text('立即解析'));
      await tester.pumpAndSettle();
      final parse = tester.state<ParsePageState>(find.byType(ParsePage));
      expect(parse.links.map((link) => link.shareId), ['Mobile123', 'Pan_123']);
      expect(parse.links.map((link) => link.passcode), ['m123', 'p123']);
      expect(parse.current!.shareId, 'Mobile123');
      expect(find.text('${CloudPlatform.c139.label}需要登录'), findsOneWidget);
      expect(http.calls, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(parse.error, '尚未完成登录，链接和提取码已保留');
      expect(parse.current!.passcode, 'm123');
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'incoming clipboard links work from another tab and ignored links stay quiet',
    (tester) async {
      clipboard = 'https://pan.quark.cn/s/abc123';
      await render(tester, tab: 2);
      await tester.tap(find.byTooltip('忽略此链接'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardLinkBanner), findsNothing);
      expect(connector.opened, isEmpty);
      expect(http.calls, isEmpty);
      clipboard = 'https://drive.uc.cn/s/newlink';
      services.clipboard.setForeground(true);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即解析'));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(
        tester
            .state<ParsePageState>(find.byType(ParsePage, skipOffstage: false))
            .current!
            .shareId,
        'newlink',
      );
      expect(connector.opened.single.shareId, 'newlink');
      await tester.pumpWidget(const SizedBox());
    },
  );

  scenario(
    'clicking the banner body starts one parse even with repeated taps',
    (tester) async {
      clipboard = 'https://drive.uc.cn/s/body123';
      await render(tester, tab: 2);
      final pending = Completer<void>();
      connector.barrier = pending.future;
      final banner = tester.widget<ClipboardLinkBanner>(
        find.byType(ClipboardLinkBanner),
      );
      await tester.tap(find.textContaining('剪贴板发现'));
      banner.onUse();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(connector.opened.single.shareId, 'body123');
      expect(find.byType(BrowserPage), findsNothing);
      pending.complete();
      await tester.pumpAndSettle();
      expect(connector.opened, hasLength(1));
      expect(connector.lists, 1);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(services.downloads.tasks, isEmpty);
    },
  );

  scenario('recognition switch stops clipboard access and is persisted', (
    tester,
  ) async {
    await render(tester, tab: 3);
    await tester.scrollUntilVisible(find.text('链接识别'), 150);
    await tester.ensureVisible(find.text('链接识别'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('链接识别'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('自动识别剪贴板链接'), 150);
    await Scrollable.ensureVisible(
      tester.element(find.text('自动识别剪贴板链接')),
      alignment: .3,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动识别剪贴板链接'));
    await tester.pumpAndSettle();
    expect(services.settings.clipboardRecognition, isFalse);
    final previous = reads;
    clipboard = 'https://drive.uc.cn/s/abc123';
    services.clipboard.setForeground(false);
    services.clipboard.setForeground(true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(reads, previous);
    expect(find.byType(ClipboardLinkBanner), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  scenario('banner fits a narrow dark window with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    clipboard = 'https://drive.uc.cn/s/abc123\nhttps://pan.quark.cn/s/abc456';
    await render(tester, dark: true);
    expect(find.byType(ClipboardLinkBanner), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('忽略此链接'));
    await tester.pumpWidget(const SizedBox());
  });
}
