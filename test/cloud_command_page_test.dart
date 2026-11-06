import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_command_resolver.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/cloud_command_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'cloud_command_resolver_test.dart'
    show commandResponse, fixtureCommandKeys;
import 'support.dart';

class _Files extends CloudConnector {
  _Files(this.platform);
  @override
  final CloudPlatform platform;
  final opened = <ParsedLink>[];
  final openedCredentials = <Credential?>[];
  int reads = 0;
  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    opened.add(link);
    openedCredentials.add(credential);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '口令分享文件',
      rootId: '0',
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    reads++;
    return const [CloudFile(id: 'file', name: '测试文档.pdf', size: 1234)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late FakeHttp http;
  late Map<CloudPlatform, _Files> connectors;
  String? copiedText;

  Future<void> render(
    WidgetTester tester, {
    bool home = false,
    Size size = const Size(393, 864),
    double scale = 1,
    String initialText = '',
    Future<ParsedLink> Function(CloudPlatform, String)? resolve,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    http = FakeHttp(
      (r) => commandResponse(
        r.uri.host.contains('quark')
            ? CloudPlatform.quark
            : r.uri.host.contains('xunlei')
            ? CloudPlatform.xunlei
            : CloudPlatform.uc,
      ),
    );
    services = AppServices(
      store: StateStore.memory(),
      dataDirectory: Directory('command-fixture'),
      cacheDirectory: Directory('command-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('command-fixture/files')),
      http: http,
      platformFeatures: false,
      controlEnabled: false,
    );
    connectors = {for (final p in CloudCommandResolver.platforms) p: _Files(p)};
    services.cloud.connectors.addAll(connectors);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: home
            ? Scaffold(body: ParsePage(services))
            : CloudCommandPage(
                services,
                initialText: initialText,
                resolveCommand:
                    resolve ??
                    CloudCommandResolver(
                      http,
                      keys: fixtureCommandKeys,
                    ).resolve,
              ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      copiedText = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      try {
        await body(tester);
      } finally {
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
      }
    });
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  scenario(
    'Plain Chinese never triggers automatic Xunlei requests and the explicit entry retains input',
    (tester) async {
      await render(tester, home: true);
      await tester.enterText(find.byKey(const Key('parse-input')), '中文分享口令');
      await tap(tester, find.byKey(const Key('parse-start')));
      expect(http.calls, isEmpty);
      expect(find.textContaining('口令解析'), findsWidgets);
      await tap(tester, find.byKey(const Key('parse-command')));
      expect(find.byType(CloudCommandPage), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('command-input')))
            .controller!
            .text,
        '中文分享口令',
      );
      expect(http.calls, isEmpty);
    },
  );

  for (final p in CloudCommandResolver.platforms) {
    scenario(
      '${p.key} accepts new token formats and opens a preloaded share with its code',
      (tester) async {
        await render(tester);
        await tap(tester, find.byKey(ValueKey('command-provider-${p.key}')));
        if (p == CloudPlatform.xunlei) {
          await services.store.put('credentials', {
            'Xunlei': Credential('fixture', {
              'accessToken': 'fixture-token',
            }, updatedAt: 1).toJson(),
          });
          await tester.enterText(
            find.byKey(const Key('command-input')),
            '新格式 @token_123- ${'a' * 80}',
          );
        } else if (p == CloudPlatform.c139) {
          await services.store.put('credentials', {
            'C139': Credential('fixture-mobile', {
              'authorization': 'fixture-mobile-authorization',
            }, updatedAt: 3).toJson(),
          });
          await tester.enterText(
            find.byKey(const Key('command-input')),
            '移动云盘分享 /*b9gaLFbe4PUz:/ 提取码：A1b2',
          );
        } else {
          await tester.enterText(
            find.byKey(const Key('command-input')),
            p == CloudPlatform.quark ? '新格式+_令牌/123' : '輸如果你不识解開',
          );
        }
        await tap(tester, find.byKey(const Key('command-start')));
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(find.text('测试文档.pdf'), findsOneWidget);
        expect(find.text('解析成功'), findsNothing);
        final expectedCode = switch (p) {
          CloudPlatform.xunlei => '1234',
          CloudPlatform.c139 => 'A1b2',
          _ => 'A%2B+B',
        };
        expect(connectors[p]!.opened.single.passcode, expectedCode);
        expect(connectors[p]!.reads, 1);
        expect(http.calls, hasLength(p == CloudPlatform.c139 ? 0 : 1));
        if (p == CloudPlatform.c139) {
          expect(connectors[p]!.opened.single.shareId, 'b9gaLFbe4PUz');
          expect(
            connectors[p]!.openedCredentials.single?.field('authorization'),
            'fixture-mobile-authorization',
          );
        }
        expect(
          services.store.data
              .list('history')
              .single
              .obj('link')
              .str('passcode'),
          expectedCode,
        );
        final saved = services.commandHistory.all.single;
        expect(saved.platform, p);
        expect(saved.link.passcode, expectedCode);
        expect(saved.title, '口令分享文件');
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(CloudCommandPage), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('command-input')))
              .controller!
              .text,
          isNotEmpty,
        );
      },
    );
  }

  scenario(
    'Mobile command requires the app account, preserves input on cancellation and retries with its credential',
    (tester) async {
      const command = '/*b9gaLFbe4PUz:/';
      await render(tester);
      await tap(tester, find.byKey(const ValueKey('command-provider-C139')));
      await tester.enterText(find.byKey(const Key('command-input')), command);
      final start = find.byKey(const Key('command-start'));
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      await tester.tap(start);
      // Parsing waits for this dialog while its progress indicator animates.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('本 App 内登录账号的授权信息'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(connectors[CloudPlatform.c139]!.opened, isEmpty);
      expect(http.calls, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('请先在本 App 登录移动云盘后再解析，口令已保留'), findsOneWidget);
      expect(find.text('去登录并继续'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('command-input')))
            .controller!
            .text,
        command,
      );
      expect(services.commandHistory.all, isEmpty);
      await services.store.put('credentials', {
        'C139': Credential('app-user', {
          'authorization': 'app-user-authorization',
        }, updatedAt: 5).toJson(),
      });
      await tap(tester, find.byKey(const Key('command-start')));
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(
        connectors[CloudPlatform.c139]!.openedCredentials.single?.field(
          'authorization',
        ),
        'app-user-authorization',
      );
      expect(services.commandHistory.all.single.text, command);
      expect(http.calls, isEmpty);
    },
  );

  scenario(
    'Chinese mobile command selects mobile cloud and opens with the app account',
    (tester) async {
      const text = '“蕧郅岱等遥温琴扣炩”';
      await render(tester, initialText: text);
      expect(find.textContaining('支持移动云盘文字口令'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('command-input')))
            .controller!
            .text,
        text,
      );
      expect(http.calls, isEmpty);
      await services.store.put('credentials', {
        'C139': Credential('app-user', {
          'authorization': 'app-user-authorization',
        }, updatedAt: 5).toJson(),
      });
      await tap(tester, find.byKey(const Key('command-start')));
      expect(find.byType(BrowserPage), findsOneWidget);
      final opened = connectors[CloudPlatform.c139]!.opened.single;
      expect(opened.shareId, '蕧郅岱等遥温琴扣炩');
      expect(Uri.parse(opened.url).queryParameters['linkCode'], opened.shareId);
      expect(
        connectors[CloudPlatform.c139]!.openedCredentials.single?.field(
          'authorization',
        ),
        'app-user-authorization',
      );
      expect(services.commandHistory.all.single.text, text);
      expect(http.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  scenario('Existing Quark Chinese command keeps the selected provider', (
    tester,
  ) async {
    const text = '咐置松君杂货铺叩苓';
    await render(tester, initialText: text);
    expect(find.textContaining('支持移动云盘文字口令'), findsNothing);
    await tap(tester, find.byKey(const Key('command-start')));
    expect(connectors[CloudPlatform.quark]!.opened, hasLength(1));
    expect(connectors[CloudPlatform.c139]!.opened, isEmpty);
    expect(http.calls.single.uri.host, 'utoken2.quark.cn');
  });

  scenario('Quark short tokens open the share page after manual submission', (
    tester,
  ) async {
    await render(tester);
    await tester.enterText(
      find.byKey(const Key('command-input')),
      '/~62003YrHLe~:/',
    );
    expect(http.calls, isEmpty);
    await tap(tester, find.byKey(const Key('command-start')));
    expect(find.byType(BrowserPage), findsOneWidget);
    expect(find.text('测试文档.pdf'), findsOneWidget);
    expect(http.calls, hasLength(1));
    expect(http.calls.single.uri.host, 'utoken2.quark.cn');
    expect(connectors[CloudPlatform.quark]!.reads, 1);
  });

  scenario(
    'Manual selection keeps separate drafts and remembers the last platform without network calls',
    (tester) async {
      await render(tester);
      await tester.enterText(find.byKey(const Key('command-input')), '夸克输入');
      await tap(tester, find.byKey(const ValueKey('command-provider-Uc')));
      await tester.enterText(find.byKey(const Key('command-input')), 'UC输入');
      await tap(tester, find.byKey(const ValueKey('command-provider-Quark')));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('command-input')))
            .controller!
            .text,
        '夸克输入',
      );
      await tap(tester, find.byKey(const ValueKey('command-provider-Uc')));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('command-input')))
            .controller!
            .text,
        'UC输入',
      );
      expect(services.store.data.str('commandParsePlatform'), 'Uc');
      expect(http.calls, isEmpty);
    },
  );

  scenario(
    'Cancelled commands cannot open late results or store successful history',
    (tester) async {
      final done = Completer<ParsedLink>();
      await render(tester, resolve: (_, _) => done.future);
      await tester.enterText(
        find.byKey(const Key('command-input')),
        '咐置松君杂货铺叩苓',
      );
      final start = find.byKey(const Key('command-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.ensureVisible(find.text('取消解析'));
      await tester.tap(find.text('取消解析'));
      await tester.pumpAndSettle();
      done.complete(
        ParsedLink(
          source: 'https://pan.quark.cn/s/fixture',
          url: 'https://pan.quark.cn/s/fixture',
          kind: LinkKind.cloudShare,
          platform: CloudPlatform.quark,
          shareId: 'fixture',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsNothing);
      expect(connectors[CloudPlatform.quark]!.opened, isEmpty);
      expect(services.store.data.list('history'), isEmpty);
      expect(services.commandHistory.all, isEmpty);
      expect(find.text('解析已取消，口令已保留'), findsOneWidget);
    },
  );

  scenario(
    'Command history restores the exact text and provider without parsing on copy or use',
    (tester) async {
      const original = '  輸如果你不识解開 + %2B e\u0301 👩🏽‍💻\n';
      await render(tester);
      await tester.enterText(find.byKey(const Key('command-input')), '夸克草稿');
      await tap(tester, find.byKey(const Key('command-provider-Uc')));
      await tester.enterText(find.byKey(const Key('command-input')), original);
      await tap(tester, find.byKey(const Key('command-start')));
      expect(find.byType(BrowserPage), findsOneWidget);
      final saved = services.commandHistory.all.single;
      expect(saved.text, original);
      expect(saved.itemCount, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('command-provider-Quark')));
      await tap(tester, find.byKey(const Key('command-history')));
      await tap(tester, find.byTooltip('复制口令'));
      expect(copiedText, original);
      expect(find.byKey(const Key('command-history-sheet')), findsOneWidget);
      expect(http.calls, hasLength(1));
      await tap(tester, find.text('口令分享文件'));
      expect(find.byKey(const Key('command-history-sheet')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('command-input')))
            .controller!
            .text,
        original,
      );
      expect(services.store.data.str('commandParsePlatform'), 'Uc');
      expect(http.calls, hasLength(1));
      await tap(tester, find.byKey(const Key('command-provider-Quark')));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('command-input')))
            .controller!
            .text,
        '夸克草稿',
      );
      await tap(tester, find.byKey(const Key('command-provider-Uc')));
      await tap(tester, find.byKey(const Key('command-start')));
      expect(http.calls, hasLength(2));
      expect(services.commandHistory.all.single.id, saved.id);
      expect(services.commandHistory.all.single.text, original);
    },
  );

  scenario(
    'Command history deletes one entry and confirms before clearing the rest',
    (tester) async {
      await render(tester);
      for (final text in ['第一条原口令', '第二条原口令']) {
        await services.remember(
          ParsedLink(
            source: 'https://pan.quark.cn/s/fixture',
            url: 'https://pan.quark.cn/s/fixture',
            kind: LinkKind.cloudShare,
            platform: CloudPlatform.quark,
          ),
          commandText: text,
          title: text,
        );
      }
      await tap(tester, find.byKey(const Key('command-history')));
      await tap(tester, find.byTooltip('删除这条口令').first);
      expect(services.commandHistory.all.single.text, '第一条原口令');
      await tap(tester, find.text('清空'));
      await tap(tester, find.text('取消'));
      expect(services.commandHistory.all, hasLength(1));
      await tap(tester, find.text('清空'));
      await tap(tester, find.text('确定'));
      expect(services.commandHistory.all, isEmpty);
      expect(find.text('暂无口令历史'), findsOneWidget);
      expect(services.store.data.list('history'), hasLength(1));
      expect(http.calls, isEmpty);
    },
  );

  scenario('Failed or rejected commits do not add command history', (
    tester,
  ) async {
    await render(
      tester,
      resolve: (_, _) async => throw const AppException('口令已失效'),
    );
    await tester.enterText(find.byKey(const Key('command-input')), '失败的口令');
    await tap(tester, find.byKey(const Key('command-start')));
    expect(find.text('口令已失效'), findsOneWidget);
    expect(services.commandHistory.all, isEmpty);
    await services.remember(
      ParsedLink(
        source: 'https://pan.quark.cn/s/test',
        url: 'https://pan.quark.cn/s/test',
        kind: LinkKind.cloudShare,
        platform: CloudPlatform.quark,
      ),
      commandText: '不可提交的口令',
      canCommit: () => false,
    );
    expect(services.commandHistory.all, isEmpty);
    expect(services.store.data.list('history'), isEmpty);
  });

  scenario(
    'Closing a command page before the resolver finishes cannot record history',
    (tester) async {
      final result = Completer<ParsedLink>();
      await render(tester, resolve: (_, _) => result.future);
      await tester.enterText(find.byKey(const Key('command-input')), '尚未完成的口令');
      await tester.ensureVisible(find.byKey(const Key('command-start')));
      await tester.tap(find.byKey(const Key('command-start')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('command-history')))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      result.complete(
        ParsedLink(
          source: 'https://pan.quark.cn/s/late',
          url: 'https://pan.quark.cn/s/late',
          kind: LinkKind.cloudShare,
          platform: CloudPlatform.quark,
        ),
      );
      await tester.pumpAndSettle();
      expect(services.commandHistory.all, isEmpty);
      expect(services.store.data.list('history'), isEmpty);
      expect(connectors[CloudPlatform.quark]!.opened, isEmpty);
    },
  );

  for (final (size, scale) in [
    (const Size(320, 700), 1.8),
    (const Size(844, 390), 1.0),
    (const Size(1280, 800), 1.0),
  ]) {
    scenario('Manual command controls fit $size at text scale $scale', (
      tester,
    ) async {
      await render(tester, size: size, scale: scale);
      await tap(tester, find.byKey(const ValueKey('command-provider-Uc')));
      await tester.enterText(
        find.byKey(const Key('command-input')),
        '~U_Cfc773YARWW~',
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('command-start')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tap(tester, find.byKey(const Key('command-start')));
      expect(find.byType(BrowserPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('command-history')));
      expect(find.byTooltip('复制口令').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
