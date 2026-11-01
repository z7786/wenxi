import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/parser_rules/server.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/providers/baidu_public_password.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/parser_site_picker.dart';
import 'baidu_public_parser_support.dart';
import 'support.dart';

// Disk persistence is covered by parser_rules_test. Keep widget timing in one zone.
class _WidgetRuleHub extends ParserRuleHub {
  _WidgetRuleHub({
    required super.store,
    required super.directory,
    required super.http,
    required super.url,
    required super.apiKey,
    required super.publicKey,
    required super.clock,
    String fixtureName = 'bundle-1',
    this.visible = true,
  }) {
    bundle = ParserBundle.verify(
      asJson(
        jsonDecode(
          File(
            'test/fixtures/parser_rules/$fixtureName.json',
          ).readAsStringSync(),
        ),
      ),
      publicKey,
      now: clock(),
    );
  }
  late ParserBundle bundle;
  List<ParserSite>? sitesOverride;
  int forcedRefreshes = 0;
  bool visible;
  @override
  List<ParserSite> get sites => visible ? sitesOverride ?? bundle.sites : [];
  @override
  void start() {}
  @override
  Future<bool> refresh({bool force = false}) async {
    if (force) forcedRefreshes++;
    return false;
  }

  void useFixture(String name) {
    bundle = ParserBundle.verify(
      asJson(
        jsonDecode(
          File('test/fixtures/parser_rules/$name.json').readAsStringSync(),
        ),
      ),
      publicKey,
      now: clock(),
    );
    sitesOverride = null;
    notifyListeners();
  }

  void updatePrompt({ParserPasswordPrompt? prompt, String? url}) {
    final site = sites.first;
    sitesOverride = [
      ParserSite(
        bundleId: site.bundleId,
        version: site.version,
        rule: site.rule,
        guide: site.guide,
        obtainUrl: url ?? site.obtainUrl,
        guideImages: site.guideImages,
        passwordPrompt: prompt ?? site.passwordPrompt,
      ),
    ];
    notifyListeners();
  }

  @override
  Future<ParserSite?> forNewShare({
    String? siteId,
    CloudPlatform platform = CloudPlatform.baidu,
  }) async {
    if (!visible) {
      visible = true;
      notifyListeners();
    }
    return sitesFor(
      platform,
    ).where((site) => siteId == null || site.id == siteId).firstOrNull;
  }

  @override
  Future<ParserSite> snapshot(String bundleId, String siteId) async =>
      sites.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late ParserRuleHub hub;
  late FakeHttp http;
  late bool passwordAvailable;
  late bool serverPending;
  late String submissionStatus;
  late bool passwordNetworkFails;
  final now = DateTime.fromMillisecondsSinceEpoch(1791936000000);
  Future<void> prepare(
    WidgetTester tester, {
    bool serverChannel = false,
    bool workflowChannel = false,
    bool deferRules = false,
    String? manifest,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 960);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    directory = Directory('parser-rule-widget-fixture');
    final store = StateStore.memory();
    final fixture = BaiduPublicFixture();
    final fixtureName =
        manifest ??
        (workflowChannel
            ? 'bundle-workflow'
            : serverChannel
            ? 'bundle-server'
            : 'bundle-1');
    passwordAvailable = false;
    serverPending = false;
    submissionStatus = 'accepted';
    passwordNetworkFails = false;
    http = FakeHttp((request) {
      if (workflowChannel && request.uri.host == 'file.mdx.wang') {
        return switch (request.uri.path) {
          '/api/session' => jsonResponse({
            'error': 0,
            'token': 'session',
            'secret': 'fixture',
            'nonce': 'nonce',
          }),
          '/api/pandl/submit' => jsonResponse({'error': 0, 'token': 'task'}),
          '/api/pandl/files' =>
            serverPending
                ? jsonResponse({'pending': true}, 202)
                : jsonResponse({
                    'error': 0,
                    'files': [
                      {
                        'fsid': BaiduPublicFixture.fileId,
                        'name': BaiduPublicFixture.name,
                        'size': 12,
                      },
                    ],
                  }),
          _ => throw StateError('Unexpected workflow request'),
        };
      }
      if (request.uri.host == 'hub.example.com') {
        if (request.uri.path == '/v1/sites') {
          if (passwordNetworkFails) {
            throw const SocketException('fixture offline');
          }
          return jsonResponse({
            'ok': true,
            'data': {
              'sites': [
                {
                  'id': hub.sites.first.id,
                  'version': passwordAvailable ? 1 : 0,
                },
              ],
            },
          });
        }
        if (request.uri.path == '/v1/rules') {
          return jsonResponse({
            'ok': true,
            'data': jsonDecode(
              File(
                'test/fixtures/parser_rules/$fixtureName.json',
              ).readAsStringSync(),
            ),
          });
        }
        if (serverChannel &&
            (request.uri.path == '/v1/parser/jobs' ||
                request.uri.path == '/v1/parser/jobs/${'c' * 32}')) {
          return jsonResponse({
            'ok': true,
            'data': {
              'id': 'c' * 32,
              'siteId': hub.sites.first.id,
              'ruleHash': ParserServerClient.hash(hub.sites.first.rule),
              'status': serverPending ? 'running' : 'succeeded',
              'stage': serverPending ? 'queue' : 'done',
              'progress': {'position': 1},
              'list': [fixture.file()],
            },
          });
        }
        if (request.uri.path.endsWith('/password')) {
          if (passwordNetworkFails) {
            throw const SocketException('fixture offline');
          }
          return jsonResponse({
            'ok': true,
            'data': {
              'password': passwordAvailable ? '已验证密码' : null,
              'version': passwordAvailable ? 1 : 0,
              'cacheFor': 300,
            },
          });
        }
        if (request.uri.path.endsWith('/submissions')) {
          passwordAvailable = submissionStatus == 'accepted';
          return jsonResponse({
            'ok': true,
            'data': {'id': 'b' * 32, 'status': submissionStatus},
          });
        }
        throw StateError(request.uri.path);
      }
      return fixture.respond(request);
    });
    hub = _WidgetRuleHub(
      store: Vault(store),
      directory: directory,
      http: http,
      url: 'https://hub.example.com',
      apiKey: 'test-app-key',
      publicKey: File(
        'test/fixtures/parser_rules/${workflowChannel ? 'workflow-public-key.txt' : 'public-key.txt'}',
      ).readAsStringSync(),
      clock: () => workflowChannel ? DateTime.utc(2026, 10, 17, 5) : now,
      fixtureName: fixtureName,
      visible: !deferRules,
    );
    // Cache discovery uses real filesystem I/O even when no legacy cache
    // exists. Finish that work outside the widget clock before testing UI.
    await tester.runAsync(() => hub.ensurePublicParsing(CloudPlatform.baidu));
    services = AppServices(
      store: store,
      dataDirectory: directory,
      cacheDirectory: directory,
      transport: FakeNative(),
      files: FakeFiles(directory),
      http: http,
      platformFeatures: false,
      controlEnabled: false,
      parserRuleHub: hub,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(body: ParsePage(services)),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('parse-input')),
      BaiduPublicFixture.url,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('公益解析').first);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    services.close().then((_) => closed = true);
    for (var i = 0; i < 100 && !closed; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(closed, true);
  }

  testWidgets(
    'Clicking a recognized share prompts for its parser password and continues after acceptance',
    (tester) async {
      await prepare(tester);
      try {
        expect(find.byType(ParserSitePicker), findsOneWidget);
        expect(find.byKey(const Key('parser-password-button')), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('parse-recognized-action')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('parse-recognized-action')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('parser-password-input')), findsOneWidget);
        expect(find.text('验证'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('parser-password-input')),
          '完整密码Text!',
        );
        await tester.pump();
        await tester.tap(find.text('验证'));
        await tester.pumpAndSettle();
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(find.text(BaiduPublicFixture.name), findsOneWidget);
        final submitted = http.calls.singleWhere(
          (r) => r.uri.path.endsWith('/submissions'),
        );
        expect(submitted.json['password'], '完整密码Text!');
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Server channel opens the share without a password prompt or direct upstream request',
    (tester) async {
      await prepare(tester, serverChannel: true);
      try {
        expect(find.byKey(const Key('parser-password-button')), findsNothing);
        expect(find.byKey(const Key('parser-web-button')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('parser-password-input')), findsNothing);
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(find.text(BaiduPublicFixture.name), findsOneWidget);
        expect(
          http.calls.where((r) => r.uri.path.contains('password')),
          isEmpty,
        );
        expect(
          http.calls.every((r) => r.uri.host == 'hub.example.com'),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  Future<void> openPassword(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('parser-password-button')));
    await tester.tap(find.byKey(const Key('parser-password-button')));
    await tester.pumpAndSettle();
  }

  for (final useKeyboard in [false, true]) {
    testWidgets(
      'Legacy mf keeps manual entry despite a UC cache, keyboard: $useKeyboard',
      (tester) async {
        await prepare(tester, manifest: 'bundle-rich-prompt');
        try {
          passwordAvailable = false;
          await services.vault.putCredential(
            CloudPlatform.uc,
            Credential('UC fixture', {
              'primary': '__pus=widget-uc',
            }, updatedAt: 9),
          );
          const password = '自动获取的解析密码';
          final prefetch = BaiduPublicPasswords(
            http,
            store: services.vault,
            clock: services.clock,
            fetchAuthenticated: (_) async => password,
          );
          await prefetch.authenticated();
          await prefetch.close();
          await openPassword(tester);
          final input = find.byKey(const Key('parser-password-input'));
          expect(tester.widget<TextField>(input).controller!.text, isEmpty);
          expect(find.text('验证'), findsOneWidget);
          await tester.enterText(input, '用户填写的当前密码');
          await tester.pump();
          if (useKeyboard) {
            await tester.showKeyboard(input);
            await tester.testTextInput.receiveAction(TextInputAction.done);
          } else {
            await tester.tap(find.text('验证'));
          }
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          await tester.ensureVisible(find.byKey(const Key('parse-start')));
          await tester.tap(find.byKey(const Key('parse-start')));
          await tester.pumpAndSettle();
          expect(find.byType(BrowserPage), findsOneWidget);
          expect(
            http.calls
                .singleWhere((r) => r.uri.path.endsWith('/submissions'))
                .json['password'],
            '用户填写的当前密码',
          );
          expect(
            http.calls.where((r) => r.json.containsKey('parse_password')),
            isNotEmpty,
          );
          expect(
            http.calls
                .where((r) => r.json.containsKey('parse_password'))
                .every((r) => r.json['parse_password'] == '已验证密码'),
            true,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await finish(tester);
        }
      },
    );
  }

  testWidgets(
    'Missing and rejected passwords use the same remote title and message',
    (tester) async {
      await prepare(tester, manifest: 'bundle-prompt');
      try {
        final prompt = hub.sites.single.passwordPrompt;
        await openPassword(tester);
        expect(find.text(prompt.title), findsOneWidget);
        expect(find.text(prompt.message), findsOneWidget);
        expect(find.text(prompt.buttonText), findsOneWidget);
        expect((hub as _WidgetRuleHub).forcedRefreshes, 1);
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        submissionStatus = 'rejected';
        await tester.enterText(
          find.byKey(const Key('parser-password-input')),
          '错误的测试密码',
        );
        await tester.pump();
        await tester.tap(find.text('验证'));
        await tester.pumpAndSettle();
        expect(find.text(prompt.title), findsOneWidget);
        expect(find.text(prompt.message), findsOneWidget);
        expect(find.text(prompt.buttonText), findsOneWidget);
        expect(find.text('继续解析'), findsNothing);
        expect(find.text('查看审核结果'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'An open password dialog updates signed copy without losing typed input',
    (tester) async {
      await prepare(tester, manifest: 'bundle-prompt');
      try {
        await openPassword(tester);
        await tester.enterText(
          find.byKey(const Key('parser-password-input')),
          '正在填写的密码',
        );
        (hub as _WidgetRuleHub).useFixture('bundle-prompt-2');
        await tester.pumpAndSettle();
        expect(find.text('新的领取说明'), findsOneWidget);
        expect(find.text('请查看更新后的领取说明。'), findsOneWidget);
        expect(find.byKey(const Key('parser-password-obtain')), findsNothing);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('parser-password-input')))
              .controller!
              .text,
          '正在填写的密码',
        );
        await tester.tap(find.text('重新获取'));
        await tester.pumpAndSettle();
        expect((hub as _WidgetRuleHub).forcedRefreshes, 2);
        expect(find.text('请查看更新后的领取说明。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Configured password button opens its address in the external browser',
    (tester) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await prepare(tester, manifest: 'bundle-prompt');
      try {
        await openPassword(tester);
        await tester.tap(find.byKey(const Key('parser-password-obtain')));
        await tester.pumpAndSettle();
        expect(calls.single.method, 'launch');
        expect(
          calls.single.arguments['url'],
          'https://example.com/current-password',
        );
        expect(calls.single.arguments['useWebView'], isFalse);
        expect(calls.single.arguments['useSafariVC'], isFalse);
        expect(find.byKey(const Key('parser-password-input')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets('A missing or unsafe obtain address hides the password button', (
    tester,
  ) async {
    await prepare(tester, manifest: 'bundle-prompt');
    try {
      await openPassword(tester);
      for (final url in [
        '',
        'javascript:alert(1)',
        'https://user:secret@example.com/',
        '/relative',
      ]) {
        (hub as _WidgetRuleHub).updatePrompt(url: url);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('parser-password-obtain')), findsNothing);
      }
      (hub as _WidgetRuleHub).updatePrompt(url: 'http://example.com/password');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('parser-password-obtain')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });

  testWidgets(
    'Network and verification outages keep their own status messages',
    (tester) async {
      await prepare(tester, manifest: 'bundle-prompt');
      try {
        passwordNetworkFails = true;
        await openPassword(tester);
        final text = tester
            .widget<SelectableText>(
              find.byKey(const Key('parser-password-status')),
            )
            .data!;
        expect(text, isNotEmpty);
        expect(text, isNot(hub.sites.single.passwordPrompt.message));
        expect(find.text('继续解析'), findsNothing);
        passwordNetworkFails = false;
        await tester.tap(find.text('重新获取'));
        await tester.pumpAndSettle();
        expect(
          find.text(hub.sites.single.passwordPrompt.message),
          findsOneWidget,
        );
        submissionStatus = 'unavailable';
        await tester.enterText(
          find.byKey(const Key('parser-password-input')),
          '待验证密码',
        );
        await tester.pump();
        await tester.tap(find.text('验证'));
        await tester.pumpAndSettle();
        expect(find.textContaining('原站暂时无法验证'), findsOneWidget);
        expect(
          find.text(hub.sites.single.passwordPrompt.message),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Long password instructions scroll on a narrow phone without overflow',
    (tester) async {
      await prepare(tester, manifest: 'bundle-prompt');
      try {
        tester.view.physicalSize = const Size(320, 640);
        (hub as _WidgetRuleHub).updatePrompt(
          prompt: ParserPasswordPrompt(
            title: '领取本通道的当前解析密码',
            message: '操作步骤：请在网页领取后返回填写完整的解析密码。\n' * 70,
            buttonText: '点击前往网页获取当前完整解析密码',
          ),
        );
        await tester.pumpAndSettle();
        await openPassword(tester);
        await tester.ensureVisible(
          find.byKey(const Key('parser-password-input')),
        );
        await tester.enterText(
          find.byKey(const Key('parser-password-input')),
          '测试密码',
        );
        expect(tester.takeException(), isNull);
        expect(find.text('验证'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Rules loaded on first parse grant server queues time beyond the direct-parser deadline',
    (tester) async {
      await prepare(tester, serverChannel: true, deferRules: true);
      serverPending = true;
      try {
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(
          http.calls.where((r) => r.uri.path == '/v1/parser/jobs'),
          hasLength(1),
        );
        await tester.pump(const Duration(seconds: 91));
        expect(find.textContaining('解析超时'), findsNothing);
        expect(find.byType(BrowserPage), findsNothing);
        expect(
          tester.state<ParsePageState>(find.byType(ParsePage)).working,
          isTrue,
        );
        serverPending = false;
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Workflow loaded on first parse keeps polling beyond 90 seconds without a backend job',
    (tester) async {
      await prepare(tester, workflowChannel: true, deferRules: true);
      serverPending = true;
      try {
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(
          http.calls.where((r) => r.uri.path == '/api/pandl/submit'),
          hasLength(1),
        );
        await tester.pump(const Duration(seconds: 91));
        expect(find.textContaining('解析超时'), findsNothing);
        expect(
          tester.state<ParsePageState>(find.byType(ParsePage)).working,
          isTrue,
        );
        serverPending = false;
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(
          http.calls.where((r) => r.uri.path.startsWith('/v1/parser/jobs')),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Cancelled password input leaves account route and original share text available',
    (tester) async {
      await prepare(tester);
      try {
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('parser-password-input')), findsOneWidget);
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(find.byType(BrowserPage), findsNothing);
        expect(find.text('账号下载'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('parse-input')))
              .controller!
              .text,
          BaiduPublicFixture.url,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'A manual channel ignores cached shared passwords and asks again for a new share',
    (tester) async {
      await prepare(tester, manifest: 'bundle-generic');
      try {
        passwordAvailable = true;
        final id = hub.sites.single.id;
        await hub.password(id);
        (hub as _WidgetRuleHub).updatePrompt(
          prompt: const ParserPasswordPrompt(autoFill: false),
        );
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('继续解析'), findsNothing);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('parser-password-input')))
              .controller!
              .text,
          isEmpty,
        );
        await tester.tap(find.text('重新获取'));
        await tester.pumpAndSettle();
        expect(find.text('继续解析'), findsNothing);
        await tester.enterText(
          find.byKey(const Key('parser-password-input')),
          '人工取得的密码',
        );
        await tester.pump();
        await tester.tap(find.text('验证'));
        await tester.pumpAndSettle();
        final browser = tester.widget<BrowserPage>(find.byType(BrowserPage));
        expect(browser.session.meta('parserPasswordGrant'), hasLength(48));
        await services.cloud.list(browser.session, BaiduPublicFixture.folder);
        await services.cloud.ensureParserPassword(browser.session);
        expect(find.byType(AlertDialog), findsNothing);
        Navigator.of(tester.element(find.byType(BrowserPage))).pop();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('parser-password-input')), findsOneWidget);
        expect(find.text('继续解析'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'mf without UC login asks for input even if a shared password is already available',
    (tester) async {
      await prepare(tester);
      try {
        passwordAvailable = true;
        await hub.password('mf_dg22');
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('parser-password-input')), findsOneWidget);
        expect(find.text('继续解析'), findsNothing);
        expect(http.calls.every((r) => r.uri.host == 'hub.example.com'), true);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Markdown password notices are selectable, scroll on narrow screens and copy the complete content',
    (tester) async {
      await prepare(tester, manifest: 'bundle-rich-prompt');
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
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
        tester.view.physicalSize = const Size(320, 640);
        await tester.pumpAndSettle();
        await openPassword(tester);
        final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
        expect(body.selectable, true);
        expect(find.byType(Table), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('parser-password-copy')));
        await tester.pumpAndSettle();
        expect(copied, contains(hub.sites.single.passwordPrompt.message));
        expect(copied, contains('https://example.com/current-password'));
        await tester.ensureVisible(
          find.byKey(const Key('parser-password-input')),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );
}
