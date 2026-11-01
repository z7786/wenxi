import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/baidu_share_route.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/baidu_download_prompt.dart';
import 'package:asterlink/ui/baidu_share_route_picker.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'baidu_public_parser_support.dart';
import 'support.dart';

// Signed policy persistence is tested separately; this hub drives UI updates.
class _ToggleHub extends ParserRuleHub {
  _ToggleHub({
    required super.store,
    required super.directory,
    required super.http,
  }) : super(url: '', apiKey: '', publicKey: '', backupUrl: '');

  bool _open = true;

  void setOpen(bool value) {
    _open = value;
    notifyListeners();
  }

  @override
  bool publicParsingAllowed(CloudPlatform platform) =>
      platform != CloudPlatform.baidu || _open;

  @override
  void start() {}

  // Route tests assume an authorized parser. Actual password entry and grants
  // are exercised by parser_rules_widget_test.dart.
  @override
  ParserSharedPassword? grantedPassword(String id, String? token) =>
      id == 'mf_dg22'
      ? ParserSharedPassword(
          BaiduPublicFixture.password,
          -1,
          DateTime.utc(2099),
        )
      : null;

  @override
  Future<ParserSite?> forNewShare({
    String? siteId,
    CloudPlatform platform = CloudPlatform.baidu,
  }) async {
    checkPublicParsing(platform);
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late BaiduPublicFixture fixture;
  late FakeHttp http;
  late _ToggleHub hub;

  Future<void> render(WidgetTester tester, {bool loggedIn = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 960);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    fixture = BaiduPublicFixture();
    http = FakeHttp(fixture.respond);
    final store = StateStore.memory({
      ...fixture.authenticatedState,
      'credentials': {
        ...fixture.authenticatedState.obj('credentials'),
        if (loggedIn)
          'Baidu': Credential('fixture', {
            'primary': 'BDUSS=fixture',
          }, updatedAt: 1).toJson(),
      },
    });
    hub = _ToggleHub(
      store: Vault(store),
      directory: Directory('baidu-public-fixture'),
      http: http,
    );
    services = AppServices(
      controlEnabled: false,
      store: store,
      parserRuleHub: hub,
      dataDirectory: Directory('baidu-public-fixture'),
      cacheDirectory: Directory('baidu-public-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('baidu-public-fixture/files')),
      http: http,
      platformFeatures: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(body: ParsePage(services)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('parse-input')),
      BaiduPublicFixture.url,
    );
    await tester.pumpAndSettle();
  }

  Future<void> choosePublic(WidgetTester tester) async {
    final route = find.byKey(const ValueKey('baidu-route-mf_dg22'));
    await tester.ensureVisible(route);
    await tester.tap(route);
    await tester.pumpAndSettle();
  }

  Future<void> parse(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('parse-start')));
    await tester.tap(find.byKey(const Key('parse-start')));
    await tester.pumpAndSettle();
  }

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
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

  scenario('Baidu defaults to account parsing and uses the logged-in account', (
    tester,
  ) async {
    await render(tester, loggedIn: true);
    await enter(tester);
    expect(
      tester
          .widget<BaiduShareRoutePicker>(find.byType(BaiduShareRoutePicker))
          .value,
      BaiduShareRoute.account,
    );
    await parse(tester);
    final browser = tester.widget<BrowserPage>(find.byType(BrowserPage));
    expect(
      BaiduShareRoute.fromSession(browser.session),
      BaiduShareRoute.account,
    );
    expect(
      http.calls.every((call) => call.uri.host == 'pan.baidu.com'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  scenario(
    'Baidu account default asks for login and retains input when cancelled',
    (tester) async {
      await render(tester);
      await enter(tester);
      await parse(tester);
      expect(find.text('百度网盘需要登录'), findsOneWidget);
      expect(find.byType(BrowserPage), findsNothing);
      expect(http.calls, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('parse-input')))
            .controller!
            .text,
        BaiduPublicFixture.url,
      );
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Baidu can explicitly choose public parsing and open its files without login',
    (tester) async {
      await render(tester);
      await enter(tester);
      await choosePublic(tester);
      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .map((chip) => chip.key)
            .where(
              (key) =>
                  key == const ValueKey('baidu-route-account') ||
                  key == const ValueKey('baidu-route-mf_dg22'),
            ),
        [
          const ValueKey('baidu-route-account'),
          const ValueKey('baidu-route-mf_dg22'),
        ],
      );
      expect(
        tester
            .widget<BaiduShareRoutePicker>(find.byType(BaiduShareRoutePicker))
            .value,
        BaiduShareRoute.publicParser,
      );
      await parse(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.byType(WebLoginPage), findsNothing);
      expect(find.text(BaiduPublicFixture.name), findsOneWidget);
      expect(
        http.calls.every((call) => call.uri.host == 'mf.dg22.top'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'a parser outage leaves account parsing selectable on the input page',
    (tester) async {
      await render(tester, loggedIn: true);
      fixture.publicFailure = true;
      await enter(tester);
      await choosePublic(tester);
      await parse(tester);
      expect(find.byType(BrowserPage), findsNothing);
      expect(find.textContaining('解析站暂不可用'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('baidu-route-account')),
      );
      await tester.tap(find.byKey(const ValueKey('baidu-route-account')));
      await tester.pumpAndSettle();
      await parse(tester);
      final browser = tester.widget<BrowserPage>(find.byType(BrowserPage));
      expect(
        BaiduShareRoute.fromSession(browser.session),
        BaiduShareRoute.account,
      );
      expect(http.calls.last.uri.host, 'pan.baidu.com');
    },
  );

  scenario('share browsing can switch between public and account routes', (
    tester,
  ) async {
    await render(tester, loggedIn: true);
    await enter(tester);
    await choosePublic(tester);
    await parse(tester);
    await tester.tap(find.byKey(const ValueKey('baidu-route-account')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BaiduShareRoutePicker>(find.byType(BaiduShareRoutePicker))
          .value,
      BaiduShareRoute.account,
    );
    expect(find.text(BaiduPublicFixture.name), findsOneWidget);
    expect(http.calls.last.uri.host, 'pan.baidu.com');
    await tester.tap(find.byKey(const ValueKey('baidu-route-mf_dg22')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BaiduShareRoutePicker>(find.byType(BaiduShareRoutePicker))
          .value,
      BaiduShareRoute.publicParser,
    );
    expect(http.calls.last.uri.host, 'mf.dg22.top');
    expect(tester.takeException(), isNull);
  });

  scenario('public downloads do not display the account channel size notice', (
    tester,
  ) async {
    await render(tester);
    final session = await services.cloud.share(
      fixture.link,
      baiduRoute: BaiduShareRoute.publicParser,
    );
    bool? accepted;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                accepted = await confirmBaiduDownload(
                  context,
                  services,
                  CloudPlatform.baidu,
                  session: session,
                );
              },
              child: const Text('下载测试'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载测试'));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
    expect(find.byKey(const ValueKey('baidu-download-notice')), findsNothing);
    expect(services.settings.hideBaiduDownloadNotice, isFalse);
  });

  scenario(
    'Closing public parsing hides its entry and requires account login until reopened',
    (tester) async {
      await render(tester);
      await enter(tester);
      expect(find.byType(BaiduShareRoutePicker), findsOneWidget);
      hub.setOpen(false);
      await tester.pumpAndSettle();
      expect(find.byType(BaiduShareRoutePicker), findsNothing);
      await parse(tester);
      expect(find.text('百度网盘需要登录'), findsOneWidget);
      expect(find.byType(BrowserPage), findsNothing);
      expect(http.calls, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      hub.setOpen(true);
      await tester.pumpAndSettle();
      expect(find.byType(BaiduShareRoutePicker), findsOneWidget);
      await choosePublic(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('parse-input')))
            .controller!
            .text,
        BaiduPublicFixture.url,
      );
      await parse(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(
        http.calls.every((call) => call.uri.host == 'mf.dg22.top'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Closing public parsing sends a logged-in user through account parsing',
    (tester) async {
      await render(tester, loggedIn: true);
      await enter(tester);
      hub.setOpen(false);
      await tester.pumpAndSettle();
      await parse(tester);
      final browser = tester.widget<BrowserPage>(find.byType(BrowserPage));
      expect(
        BaiduShareRoute.fromSession(browser.session),
        BaiduShareRoute.account,
      );
      expect(find.byType(BaiduShareRoutePicker), findsNothing);
      expect(find.text(BaiduPublicFixture.name), findsOneWidget);
      expect(
        http.calls.every((call) => call.uri.host == 'pan.baidu.com'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'An open public share keeps its account exit after closure and restores routes on reopen',
    (tester) async {
      await render(tester, loggedIn: true);
      await enter(tester);
      await choosePublic(tester);
      await parse(tester);
      final before = http.calls.length;
      hub.setOpen(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('baidu-route-mf_dg22')), findsNothing);
      expect(find.byKey(const ValueKey('baidu-route-account')), findsOneWidget);
      expect(find.text('公益解析暂未开放，请切换账号下载'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('baidu-route-account')));
      await tester.pumpAndSettle();
      expect(find.byType(BaiduShareRoutePicker), findsNothing);
      expect(find.text(BaiduPublicFixture.name), findsOneWidget);
      expect(
        http.calls
            .skip(before)
            .every((call) => call.uri.host == 'pan.baidu.com'),
        isTrue,
      );
      hub.setOpen(true);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BaiduShareRoutePicker>(find.byType(BaiduShareRoutePicker))
            .value,
        BaiduShareRoute.account,
      );
      await tester.tap(find.byKey(const ValueKey('baidu-route-mf_dg22')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BaiduShareRoutePicker>(find.byType(BaiduShareRoutePicker))
            .value,
        BaiduShareRoute.publicParser,
      );
      expect(http.calls.last.uri.host, 'mf.dg22.top');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('route controls wrap on narrow screens with enlarged text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.8),
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: BaiduShareRoutePicker(
                value: BaiduShareRoute.publicParser,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('公益解析'), findsOneWidget);
    expect(find.text('账号下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
