import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Cookie;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/providers/guangya_login.dart';
import 'package:asterlink/data/providers/ctfile.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/ctfile_captcha.dart';
import 'package:asterlink/domain/aliyun_web_password.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/weiyun_web_login.dart';
import 'package:asterlink/domain/tianyi_web_login.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/ui/guangya_verification_page.dart';
import 'package:asterlink/ui/ctfile_verification_page.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

class _Services extends AppServices {
  _Services(Directory directory)
    : super(
        store: StateStore.memory(),
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${directory.path}/saved')),
        http: LoginHttp((_) => throw StateError('Unexpected network request')),
        platformFeatures: false,
      );
  bool failInitialization = false;
  @override
  Future<WebViewEnvironment?> webEnvironment() async {
    if (failInitialization) throw StateError('Fixture WebView unavailable');
    return null;
  }
}

class _Cookies extends PlatformCookieManager {
  _Cookies()
    : super.implementation(const PlatformCookieManagerCreationParams());
  final pending = <PlatformInAppWebViewController, Completer<List<Cookie>>>{};
  final reads = <PlatformInAppWebViewController, int>{};
  final values = <String, List<Cookie>>{};
  int deleteAllCalls = 0;
  bool failRead = false;
  bool failClear = false;
  @override
  Future<bool> deleteAllCookies() async {
    deleteAllCalls++;
    if (failClear) throw StateError('Fixture cookie cleanup failed');
    return true;
  }

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    if (webViewController == null) return [];
    reads.update(webViewController, (count) => count + 1, ifAbsent: () => 1);
    if (failRead) throw StateError('Cookie: private-read-secret');
    return await pending[webViewController]?.future ??
        values[url.toString()] ??
        [];
  }
}

class _Controller extends PlatformInAppWebViewController {
  _Controller(int id)
    : super.implementation(
        PlatformInAppWebViewControllerCreationParams(id: id),
      );
}

class _CtfileController extends _Controller {
  _CtfileController(super.id, this.challenge);
  final CtfileCaptchaChallenge challenge;
  late WebUri url = WebUri.uri(challenge.url);
  Json? message;
  Completer<dynamic>? pending;
  bool navigateDuringCapture = false;
  int captures = 0;
  @override
  Future<WebUri?> getUrl() async => url;
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source != challenge.captureScript) return null;
    captures++;
    if (navigateDuringCapture) url = WebUri('https://untrusted.invalid/');
    if (pending != null) return pending!.future;
    final current = message;
    message = null;
    return current == null ? '' : jsonEncode(current);
  }
}

class _StorageController extends _Controller {
  _StorageController(super.id, this.target, {required this.navigateDuringRead});
  final WebLoginTarget target;
  final bool navigateDuringRead;
  late WebUri url = WebUri(target.url);
  int clears = 0, reads = 0, reloads = 0;
  bool prepared = false;
  @override
  Future<WebUri?> getUrl() async => url;
  @override
  Future<void> reload() async {
    reloads++;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.contains('__asterlink_login_${target.platform.key}')) {
      if (prepared) return 'ready';
      clears++;
      prepared = true;
      return 'cleared';
    }
    if (source == target.readStorageScript) {
      reads++;
      if (navigateDuringRead) url = WebUri('https://unrelated.example/');
      if (target.platform == CloudPlatform.ilanzou) {
        return jsonEncode({'appToken': accessToken, 'uuid': 'fixture-device'});
      }
      return jsonEncode({
        'access_token': accessToken,
        'refresh_token': refreshToken,
      });
    }
    return null;
  }
}

class _WeiyunController extends _Controller {
  _WeiyunController(super.id, {this.navigateDuringRead = false});
  final bool navigateDuringRead;
  WebUri url = WebUri('https://www.weiyun.com/disk');
  @override
  Future<WebUri?> getUrl() async => url;
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source == WeiyunWebLogin.readScript) {
      if (navigateDuringRead) url = WebUri('https://untrusted.invalid/');
      return jsonEncode({
        'cookie': 'weiyun_qq_openid=private-qq-fixture',
        'tokenInfo': {
          'token_type': 3,
          'login_key_type': 1540,
          'qq_openid': 'private-qq-fixture',
        },
        'requestHeader': {'user_flag': 3, 'uin': '12345'},
        'csrf': 'private-observed-csrf',
      });
    }
    return null;
  }
}

class _TianyiController extends _Controller {
  _TianyiController(super.id, {this.navigateDuringRead = false});
  final bool navigateDuringRead;
  WebUri url = WebUri('https://cloud.189.cn/web/login.html');
  String browserId = 'private-bound-browser-id';
  final scripts = <String>[];
  @override
  Future<WebUri?> getUrl() async => url;
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    scripts.add(source);
    if (source == TianyiWebLogin.readScript) {
      if (navigateDuringRead) url = WebUri('https://untrusted.invalid/');
      return jsonEncode({'browserId': browserId});
    }
    return null;
  }
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params) : super.implementation();
  bool disposed = false;
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;
  @override
  void dispose() => disposed = true;
}

class _PasswordController extends _StorageController {
  _PasswordController(this.attempt)
    : super(
        200,
        WebLoginTarget.targets[CloudPlatform.aliyun]!,
        navigateDuringRead: false,
      );
  final AliyunWebPassword attempt;
  int submissions = 0;
  bool tokenReady = false, formReady = true;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source == attempt.statusScript) {
      if (!formReady) return 'waiting';
      return submissions == 0 ? 'ready' : 'submitted';
    }
    if (source.contains('return bridge.submit(')) {
      submissions++;
      return 'sent';
    }
    if (source == target.readStorageScript && !tokenReady) return '';
    return super.evaluateJavascript(source: source, contentWorld: contentWorld);
  }
}

class _Platform extends InAppWebViewPlatform {
  final cookies = _Cookies();
  final views = <_View>[];
  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => cookies;
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _View(params);
    views.add(view);
    return view;
  }
}

void main() {
  test('web login settings force provider pages to remain zoomable', () {
    final settings = webSettings();
    expect(settings.supportZoom, isTrue);
    expect(settings.builtInZoomControls, isTrue);
    expect(settings.displayZoomControls, isFalse);
    expect(settings.ignoresViewportScaleLimits, isTrue);
    expect(settings.incognito, isTrue);
    expect(settings.cacheEnabled, isFalse);
    expect(settings.saveFormData, isFalse);
    expect(settings.userAgent, WebLoginTarget.desktopUserAgent);
    expect(settings.preferredContentMode, UserPreferredContentMode.DESKTOP);
    expect(settings.useWideViewPort, isTrue);
    expect(settings.loadWithOverviewMode, isTrue);
    for (final target in WebLoginTarget.targets.values) {
      final browser = webSettings(
        userAgent: target.userAgent,
        desktopMode: target.desktopMode,
      );
      if (target.platform == CloudPlatform.tianyi) {
        expect(browser.userAgent, contains('Mobile'));
        expect(browser.preferredContentMode, UserPreferredContentMode.MOBILE);
        expect(browser.loadWithOverviewMode, isFalse);
        expect(Uri.parse(target.url).host, 'm.cloud.189.cn');
        expect(Uri.parse(target.url).path, '/udb/udb_login.jsp');
        continue;
      }
      expect(browser.userAgent, contains('Windows NT'));
      expect(browser.userAgent, isNot(contains('Android')));
      expect(browser.userAgent, isNot(contains('Mobile')));
      expect(browser.preferredContentMode, UserPreferredContentMode.DESKTOP);
    }
    expect(
      Uri.parse(WebLoginTarget.targets[CloudPlatform.c139]!.url).path,
      '/w/',
    );
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _Platform();
  late _Services services;
  late DiagnosticLog log;
  late Directory directory;

  setUp(() {
    InAppWebViewPlatform.instance = platform;
    platform.views.clear();
    platform.cookies.pending.clear();
    platform.cookies.reads.clear();
    platform.cookies.values.clear();
    platform.cookies.deleteAllCalls = 0;
    platform.cookies.failRead = false;
    platform.cookies.failClear = false;
    directory = Directory.systemTemp.createTempSync('asterlink-web-log-test-');
    services = _Services(directory);
    log = DiagnosticLog.open(null);
    DiagnosticLog.active = log;
  });
  tearDown(() async {
    await services.close();
    log.close();
    DiagnosticLog.active = null;
    await directory.delete(recursive: true);
  });

  Future<void> render(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WebLoginPage(
          services,
          WebLoginTarget.targets[CloudPlatform.quark]!,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  (_View, InAppWebViewController) attach(int id, {_Controller? instance}) {
    final view = platform.views.last;
    final native = instance ?? _Controller(id);
    view.params.onWebViewCreated!(
      view.controllerFromPlatform<InAppWebViewController>(native),
    );
    // Android creates separate wrappers for creation and later callbacks.
    return (view, view.controllerFromPlatform<InAppWebViewController>(native));
  }

  Future<void> openLogin(WidgetTester tester, CloudPlatform cloud) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      {
                        CloudPlatform.xunlei,
                        CloudPlatform.ctfile,
                      }.contains(cloud)
                      ? PasswordLoginFlow(services, cloud)
                      : WebLoginPage(services, WebLoginTarget.targets[cloud]!),
                ),
              ),
              child: const Text('登录测试'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('登录测试'));
    await tester.pumpAndSettle();
    if (cloud == CloudPlatform.xunlei) {
      await tester.tap(find.byKey(const ValueKey('xunlei-login-web')));
      await tester.pumpAndSettle();
    } else if (cloud == CloudPlatform.ctfile) {
      await tester.tap(find.byKey(const ValueKey('native-login-web')));
      await tester.pumpAndSettle();
    }
  }

  Future<void> detect(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('检测登录'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
  }

  Future<void> automaticPoll(
    WidgetTester tester,
    InAppWebViewController web,
  ) async {
    await tester.runAsync(() async {
      final view = platform.views.last;
      view.params.onUpdateVisitedHistory!(
        web,
        WebUri('https://my.ctfile.com/'),
        false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Ctfile web login automatically captures HttpOnly cookies and validates v4 identity',
    (tester) async {
      const cloud = CloudPlatform.ctfile;
      final http = FakeHttp((request) {
        expect(request.uri.host, 'api.ctfile.com');
        if (request.uri.path.endsWith('/exchange-token')) {
          expect(request.headers['Cookie'], 'ctfile_session=private-current');
          expect(request.json['rotate_token'], isFalse);
          return jsonResponse({
            'code': 200,
            'data': {
              'token': 'fixture-access',
              'userid': '12',
              'expires_in': 900,
            },
          });
        }
        expect(request.headers['Authorization'], 'Bearer fixture-access');
        expect(request.headers.containsKey('Cookie'), isFalse);
        return jsonResponse({
          'code': 200,
          'data': request.uri.path.endsWith('/profile/info')
              ? {'userid': '12', 'username': '城通网页登录测试'}
              : {
                  'workspaces': [
                    {
                      'id': '45',
                      'owner_id': '12',
                      'space_used': 40,
                      'space_quota': 200,
                    },
                  ],
                  'has_more': false,
                },
        });
      });
      services.login.webAuthenticators[cloud] = CtfileConnector(
        http,
      ).authenticate;
      await openLogin(tester, cloud);
      final (view, web) = attach(440);
      expect(
        view.params.initialUrlRequest!.url!.toString(),
        'https://my.ctfile.com/login',
      );
      expect(platform.cookies.deleteAllCalls, 1);
      platform
          .cookies
          .values['https://api.ctfile.com/v4/user/auth/exchange-token'] = [
        Cookie(name: 'tracking', value: 'optional'),
      ];
      await automaticPoll(tester, web);
      expect(http.calls, isEmpty);
      expect(services.vault.credential(cloud), isNull);
      platform
          .cookies
          .values['https://api.ctfile.com/v4/user/auth/exchange-token'] = [
        Cookie(
          name: 'ctfile_session',
          value: 'private-current',
          isHttpOnly: true,
        ),
      ];
      platform.cookies.values['https://my.ctfile.com'] = [
        Cookie(name: 'ctfile_session', value: 'private-stale'),
      ];
      await automaticPoll(tester, web);
      final saved = services.vault.credential(cloud);
      expect(saved?.primary, 'ctfile_session=private-current');
      expect(saved?.field('authType'), 'webCookie');
      expect(saved?.field('userId'), '12');
      expect(saved?.field('nickname'), '城通网页登录测试');
      expect(find.byType(WebLoginPage), findsNothing);
      expect(
        http.calls.where(
          (request) => request.uri.path.endsWith('/exchange-token'),
        ),
        hasLength(1),
      );
      expect(platform.cookies.deleteAllCalls, 2);
      expect(
        log.entries().map((entry) => '${entry.detail} ${entry.data}').join(),
        isNot(contains('private-')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Ctfile rejected website session stays open without saving an account',
    (tester) async {
      const cloud = CloudPlatform.ctfile;
      final http = FakeHttp(
        (request) => jsonResponse({'code': 401, 'message': '城通登录已过期，请重新登录'}),
      );
      services.login.webAuthenticators[cloud] = CtfileConnector(
        http,
      ).authenticate;
      await openLogin(tester, cloud);
      final (_, web) = attach(441);
      platform
          .cookies
          .values['https://api.ctfile.com/v4/user/auth/exchange-token'] = [
        Cookie(
          name: 'ctfile_session',
          value: 'private-expired',
          isHttpOnly: true,
        ),
      ];
      await automaticPoll(tester, web);
      expect(services.vault.credential(cloud), isNull);
      expect(find.byType(WebLoginPage), findsOneWidget);
      expect(find.text('城通登录已过期，请重新登录'), findsOneWidget);
      expect(http.calls, hasLength(1));
      await automaticPoll(tester, web);
      expect(http.calls, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Ctfile web login can switch back to password in the same route',
    (tester) async {
      await openLogin(tester, CloudPlatform.ctfile);
      expect(find.text('切换账号密码登录'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('web-login-password')));
      await tester.pumpAndSettle();
      expect(find.byType(NativePasswordLoginPage), findsOneWidget);
      expect(find.byKey(const ValueKey('native-login-web')), findsOneWidget);
      expect(find.byType(WebLoginPage), findsNothing);
      expect(services.vault.credential(CloudPlatform.ctfile), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Xunlei offers account-center login and captures only the returning cloud session',
    (tester) async {
      const cloud = CloudPlatform.xunlei;
      var validations = 0;
      services.login.webAuthenticators[cloud] = (credential) async {
        validations++;
        expect(credential.field('refreshToken'), refreshToken);
        return LoginResult(credential, const CloudAccount('迅雷网页登录测试'));
      };
      await openLogin(tester, cloud);
      final target = WebLoginTarget.targets[cloud]!;
      final native = _StorageController(420, target, navigateDuringRead: false);
      final (view, web) = attach(420, instance: native);
      final entry = view.params.initialUrlRequest!.url!;
      expect(entry.host, 'i.xunlei.com');
      expect(entry.path, '/center/account/personal/login/');
      expect(entry.queryParameters['redirect_url'], 'https://pan.xunlei.com/');

      // The fallback also clears the account center when document-start
      // injection is unavailable, without reading its separate token.
      await detect(tester);
      expect(native.clears, 1);
      expect(native.reloads, 1);
      for (final page in [
        target.url,
        'https://account.xiaomi.com/fe/service/login/password',
        'https://open-api-auth.xunlei.com/platform',
        '${target.url}&code=fixture-callback',
      ]) {
        native.url = WebUri(page);
        expect(
          await view.params.shouldOverrideUrlLoading!(
            web,
            NavigationAction(
              request: URLRequest(url: native.url),
              isForMainFrame: true,
            ),
          ),
          NavigationActionPolicy.ALLOW,
        );
        await detect(tester);
        expect(native.reads, 0);
        expect(native.clears, 1);
        expect(validations, 0);
        expect(services.vault.credential(cloud), isNull);
      }

      // Session storage on the cloud origin is independent of the account
      // center, so its previous account must be cleared once as well.
      native
        ..url = WebUri('https://pan.xunlei.com/')
        ..prepared = false;
      await detect(tester);
      expect(native.clears, 2);
      expect(native.reloads, 2);
      expect(validations, 0);
      await detect(tester);
      expect(native.reads, 1);
      expect(validations, 1);
      expect(
        services.vault.credential(cloud)?.field('refreshToken'),
        refreshToken,
      );
      expect(find.byType(WebLoginPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Tianyi mobile login keeps the official viewport through navigation and popups',
    (tester) async {
      await openLogin(tester, CloudPlatform.tianyi);
      final native = _TianyiController(410);
      final (view, web) = attach(410, instance: native);
      expect(view.params.initialUrlRequest!.url!.host, 'm.cloud.189.cn');
      expect(
        view.params.initialSettings!.preferredContentMode,
        UserPreferredContentMode.MOBILE,
      );
      expect(
        view.params.initialSettings!.userAgent,
        WebLoginTarget.mobileUserAgent,
      );
      expect(
        view.params.initialUserScripts!.any(
          (script) => script.source == desktopLoginViewportScript,
        ),
        isFalse,
      );
      view.params.onLoadStop!(web, native.url);
      await tester.pump();
      expect(native.scripts, isNot(contains(desktopLoginViewportScript)));
      expect(
        await view.params.onCreateWindow!(
          web,
          CreateWindowAction(
            windowId: 411,
            request: URLRequest(url: WebUri('https://open.e.189.cn/')),
            isForMainFrame: true,
          ),
        ),
        isTrue,
      );
      await tester.pump();
      final popup = platform.views.last;
      expect(
        popup.params.initialSettings!.preferredContentMode,
        UserPreferredContentMode.MOBILE,
      );
      expect(
        popup.params.initialSettings!.userAgent,
        WebLoginTarget.mobileUserAgent,
      );
      expect(
        popup.params.initialUserScripts!.any(
          (script) => script.source == desktopLoginViewportScript,
        ),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final cloud in [
    CloudPlatform.xunlei,
    CloudPlatform.ilanzou,
    CloudPlatform.wopan,
    CloudPlatform.guangya,
  ]) {
    testWidgets(
      '${cloud.key} detects a completed login before onLoadStop is delivered',
      (tester) async {
        services.login.webAuthenticators[cloud] = (credential) async =>
            LoginResult(credential, const CloudAccount('读取测试'));
        await openLogin(tester, cloud);
        final native = _StorageController(
          300,
          WebLoginTarget.targets[cloud]!,
          navigateDuringRead: false,
        )..prepared = true;
        if (cloud == CloudPlatform.xunlei) {
          native.url = WebUri('https://pan.xunlei.com/');
        }
        final (view, _) = attach(300, instance: native);
        expect(
          view.params.initialUserScripts!.any(
            (script) =>
                script.injectionTime ==
                    UserScriptInjectionTime.AT_DOCUMENT_START &&
                script.source.contains('__asterlink_login_${cloud.key}'),
          ),
          isTrue,
        );
        await detect(tester);
        expect(
          services.vault.credential(cloud)?.field('accessToken'),
          accessToken,
          reason: log.entries().map((entry) => entry.detail).join('\n'),
        );
        expect(native.reloads, 0);
        expect(native.clears, 0);
        expect(find.byType(WebLoginPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Weiyun detects path-scoped native cookies without a page-load event',
    (tester) async {
      const cloud = CloudPlatform.weiyun;
      services.login.webAuthenticators[cloud] = (credential) async =>
          LoginResult(credential, const CloudAccount('微云测试'));
      await openLogin(tester, cloud);
      attach(301);
      platform.cookies.values['https://www.weiyun.com/webapp/'] = [
        Cookie(
          name: 'p_skey',
          value: 'fixture-weiyun-cookie',
          isHttpOnly: true,
        ),
        Cookie(name: 'uin', value: 'o1234567'),
      ];
      await detect(tester);
      expect(
        services.vault.credential(cloud)?.primary,
        contains('p_skey=fixture-weiyun-cookie'),
      );
      expect(find.byType(WebLoginPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final failNative in [false, true]) {
    testWidgets(
      'Weiyun validates a completed QQ page with native-cookie fallback: nativeFailed=$failNative',
      (tester) async {
        const cloud = CloudPlatform.weiyun;
        var validations = 0;
        services.login.webAuthenticators[cloud] = (credential) async {
          validations++;
          expect(
            credential.primary,
            contains('weiyun_qq_openid=private-qq-fixture'),
          );
          if (!failNative) {
            expect(credential.primary, contains('login_sid=private-http-only'));
          }
          expect(credential.field('weiyunCsrf'), 'private-observed-csrf');
          expect(
            WeiyunWebLogin.tokenInfo(
              credential.field('weiyunTokenInfo'),
            )['token_type'],
            3,
          );
          return LoginResult(credential, const CloudAccount('微云测试'));
        };
        await openLogin(tester, cloud);
        final (view, _) = attach(330, instance: _WeiyunController(330));
        expect(
          view.params.initialUserScripts!.any(
            (s) => s.source == WeiyunWebLogin.bootstrapScript,
          ),
          isTrue,
        );
        platform.cookies.failRead = failNative;
        platform
            .cookies
            .values['https://www.weiyun.com/webapp/json/weiyunQdiskClient/DiskUserInfoGet'] = [
          Cookie(
            name: 'login_sid',
            value: 'private-http-only',
            isHttpOnly: true,
          ),
        ];
        platform.cookies.values['https://www.weiyun.com/disk'] = [
          Cookie(name: 'login_sid', value: 'private-stale-page-cookie'),
        ];
        await detect(tester);
        expect(validations, 1);
        expect(services.vault.credential(cloud), isNotNull);
        expect(find.byType(WebLoginPage), findsNothing);
        expect(
          log.entries().any(
            (entry) => entry.event == 'web_login.capture_state',
          ),
          isTrue,
        );
        expect(
          log.entries().map((entry) => '${entry.detail} ${entry.data}').join(),
          isNot(contains('private-')),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Weiyun navigation during capture discards the page credentials',
    (tester) async {
      var validations = 0;
      services.login.webAuthenticators[CloudPlatform.weiyun] =
          (credential) async {
            validations++;
            return LoginResult(credential, const CloudAccount('unexpected'));
          };
      await openLogin(tester, CloudPlatform.weiyun);
      attach(331, instance: _WeiyunController(331, navigateDuringRead: true));
      await detect(tester);
      expect(validations, 0);
      expect(services.vault.credential(CloudPlatform.weiyun), isNull);
      expect(find.text('暂未读取到完整凭据，请刷新网页中的文件列表后再检测'), findsOneWidget);
      expect(find.byType(WebLoginPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual detection explains when the webpage has not provided credentials',
    (tester) async {
      await render(tester);
      attach(302);
      await detect(tester);
      expect(find.text('尚未读取到完整登录信息，请进入网盘首页后再检测'), findsOneWidget);
      expect(
        log.entries().any(
          (entry) => entry.event == 'web_login.credentials_pending',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Tianyi detects the account API cookie while the mobile page stays open',
    (tester) async {
      services.login.webAuthenticators[CloudPlatform
          .tianyi] = (credential) async {
        expect(credential.primary, 'COOKIE_LOGIN_USER=private-mobile-session');
        expect(credential.field('browserId'), isEmpty);
        return LoginResult(credential, const CloudAccount('天翼测试'));
      };
      await openLogin(tester, CloudPlatform.tianyi);
      final native = _TianyiController(336)
        ..url = WebUri('https://m.cloud.189.cn/main.action?menu=true')
        ..browserId = '';
      attach(336, instance: native);
      platform
          .cookies
          .values['https://cloud.189.cn/api/open/user/getUserInfoForPortal.action'] = [
        Cookie(
          name: 'COOKIE_LOGIN_USER',
          value: 'private-mobile-session',
          isHttpOnly: true,
        ),
      ];
      await detect(tester);
      expect(
        services.vault.credential(CloudPlatform.tianyi)!.primary,
        'COOKIE_LOGIN_USER=private-mobile-session',
      );
      expect(find.byType(WebLoginPage), findsNothing);
      expect(
        log.entries().map((entry) => entry.detail).join(),
        isNot(contains('private-mobile-session')),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final landing in [
    'https://cloud.189.cn/web/redirect.html',
    'https://h5.cloud.189.cn/home.html',
  ]) {
    testWidgets(
      'Tianyi validates before the mobile promotion redirect: $landing',
      (tester) async {
        services.login.webAuthenticators[CloudPlatform
            .tianyi] = (credential) async {
          expect(credential.primary, 'COOKIE_LOGIN_USER=private-mobile-login');
          return LoginResult(credential, const CloudAccount('天翼测试'));
        };
        await openLogin(tester, CloudPlatform.tianyi);
        final native = _TianyiController(440)
          ..url = WebUri(
            'https://open.e.189.cn/api/logbox/separate/wap/index.html',
          )
          ..browserId = '';
        final (view, web) = attach(440, instance: native);
        expect(
          view.params.initialUserScripts!.any(
            (script) => script.source == TianyiWebLogin.mobileFormScript,
          ),
          true,
        );
        Future<NavigationActionPolicy?> navigate(
          String url, {
          bool main = true,
        }) => view.params.shouldOverrideUrlLoading!(
          web,
          NavigationAction(
            request: URLRequest(url: WebUri(url)),
            isForMainFrame: main,
          ),
        );
        expect(
          await navigate(
            'https://m.cloud.189.cn/callbackUnifyV2.action?ticket=private-ticket',
          ),
          NavigationActionPolicy.ALLOW,
        );
        expect(
          await navigate(landing, main: false),
          NavigationActionPolicy.ALLOW,
        );
        platform.cookies.values['https://m.cloud.189.cn/'] = [
          Cookie(
            name: 'COOKIE_LOGIN_USER',
            value: 'private-mobile-login',
            isHttpOnly: true,
          ),
        ];
        await tester.runAsync(() async {
          expect(await navigate(landing), NavigationActionPolicy.CANCEL);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        expect(
          services.vault.credential(CloudPlatform.tianyi)!.primary,
          'COOKIE_LOGIN_USER=private-mobile-login',
        );
        expect(find.byType(WebLoginPage), findsNothing);
        expect(
          log.entries().any(
            (entry) => entry.event == 'web_login.completion_redirect',
          ),
          true,
        );
        expect(
          log.entries().map((entry) => entry.detail).join(),
          isNot(contains('private-')),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('A Tianyi promotion redirect alone cannot complete login', (
    tester,
  ) async {
    await openLogin(tester, CloudPlatform.tianyi);
    final native = _TianyiController(
      441,
    )..url = WebUri('https://open.e.189.cn/api/logbox/separate/wap/index.html');
    final (view, web) = attach(441, instance: native);
    await tester.runAsync(() async {
      expect(
        await view.params.shouldOverrideUrlLoading!(
          web,
          NavigationAction(
            request: URLRequest(
              url: WebUri('https://h5.cloud.189.cn/home.html'),
            ),
            isForMainFrame: true,
          ),
        ),
        NavigationActionPolicy.CANCEL,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(services.vault.credential(CloudPlatform.tianyi), isNull);
    expect(find.byType(WebLoginPage), findsOneWidget);
    expect(find.text('天翼登录尚未完成，请在网页完成验证码或安全验证后再检测'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Tianyi keeps the login iframe binding across the completed page redirect',
    (tester) async {
      var validations = 0;
      services.login.webAuthenticators[CloudPlatform.tianyi] =
          (credential) async {
            validations++;
            expect(credential.field('browserId'), 'private-bound-browser-id');
            expect(credential.primary, 'COOKIE_LOGIN_USER=private-api-session');
            return LoginResult(credential, const CloudAccount('天翼测试'));
          };
      await openLogin(tester, CloudPlatform.tianyi);
      final native = _TianyiController(334);
      final (view, _) = attach(334, instance: native);
      expect(
        view.params.initialUserScripts!.any(
          (script) => script.source == TianyiWebLogin.bootstrapScript,
        ),
        true,
      );
      await detect(tester);
      expect(validations, 0);
      native.url = WebUri('https://cloud.189.cn/web/main/');
      native.browserId = '';
      platform
          .cookies
          .values['https://cloud.189.cn/api/open/user/getUserInfoForPortal.action'] = [
        Cookie(
          name: 'COOKIE_LOGIN_USER',
          value: 'private-api-session',
          isHttpOnly: true,
        ),
      ];
      platform.cookies.values[native.url.toString()] = [
        Cookie(name: 'COOKIE_LOGIN_USER', value: 'private-stale-page-session'),
      ];
      await detect(tester);
      expect(validations, 1);
      expect(
        services.vault.credential(CloudPlatform.tianyi)!.field('browserId'),
        'private-bound-browser-id',
      );
      expect(find.byType(WebLoginPage), findsNothing);
      expect(
        log.entries().map((entry) => entry.detail).join(),
        isNot(contains('private-')),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Tianyi discards browser metadata captured during navigation to another origin',
    (tester) async {
      await openLogin(tester, CloudPlatform.tianyi);
      attach(335, instance: _TianyiController(335, navigateDuringRead: true));
      await detect(tester);
      final capture = log
          .entries()
          .where((entry) => entry.event == 'web_login.capture_state')
          .last;
      expect(capture.data['fields'], containsPair('hasBrowserBinding', false));
      expect(services.vault.credential(CloudPlatform.tianyi), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'authorization windows retain the shared cookie jar and return to the original page',
    (tester) async {
      final os = defaultTargetPlatform;
      await openLogin(tester, CloudPlatform.weiyun);
      final (main, controller) = attach(303);
      final opened = await main.params.onCreateWindow!(
        controller,
        CreateWindowAction(
          windowId: 44,
          request: URLRequest(url: WebUri('https://open.weixin.qq.com/')),
          isForMainFrame: true,
        ),
      );
      expect(opened, isTrue);
      await tester.pumpAndSettle();
      final (popup, popupController) = attach(304);
      expect(popup.params.windowId, 44);
      expect(main.params.initialSettings!.incognito, isTrue);
      expect(
        popup.params.initialSettings!.incognito,
        os == TargetPlatform.windows,
      );
      expect(popup.params.initialSettings!.saveFormData, isFalse);
      expect(platform.cookies.deleteAllCalls, 1);
      popup.params.onCloseWindow!(popupController);
      await tester.pumpAndSettle();
      expect(find.byType(InAppWebView), findsOneWidget);
      expect(platform.cookies.deleteAllCalls, 1);
      expect(find.byType(WebLoginPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'tokens created inside an authorization window can complete the login',
    (tester) async {
      const cloud = CloudPlatform.wopan;
      services.login.webAuthenticators[cloud] = (credential) async =>
          LoginResult(credential, const CloudAccount('联通测试'));
      await openLogin(tester, cloud);
      final target = WebLoginTarget.targets[cloud]!;
      final native = _StorageController(305, target, navigateDuringRead: false)
        ..url = WebUri('https://unrelated.example/');
      final (main, controller) = attach(305, instance: native);
      await main.params.onCreateWindow!(
        controller,
        CreateWindowAction(
          windowId: 45,
          request: URLRequest(url: WebUri(target.url)),
          isForMainFrame: true,
        ),
      );
      await tester.pumpAndSettle();
      attach(
        306,
        instance: _StorageController(306, target, navigateDuringRead: false)
          ..prepared = true,
      );
      await detect(tester);
      expect(
        services.vault.credential(cloud)?.field('refreshToken'),
        refreshToken,
      );
      expect(find.byType(WebLoginPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final rejected in [false, true]) {
    testWidgets(
      'closing an SSO popup during validation still reports the result: rejected=$rejected',
      (tester) async {
        const cloud = CloudPlatform.wopan;
        final pending = Completer<void>();
        var validating = false;
        services.login.webAuthenticators[cloud] = (credential) async {
          validating = true;
          await pending.future;
          if (rejected) throw const AccountLoginRequired('授权信息已过期，请重新登录');
          return LoginResult(credential, const CloudAccount('联通授权测试'));
        };
        await openLogin(tester, cloud);
        final target = WebLoginTarget.targets[cloud]!;
        final (main, controller) = attach(
          307,
          instance: _StorageController(307, target, navigateDuringRead: false)
            ..url = WebUri('https://unrelated.example/'),
        );
        await main.params.onCreateWindow!(
          controller,
          CreateWindowAction(
            windowId: 46,
            request: URLRequest(url: WebUri(target.url)),
            isForMainFrame: true,
          ),
        );
        await tester.pumpAndSettle();
        final (popup, popupController) = attach(
          308,
          instance: _StorageController(308, target, navigateDuringRead: false)
            ..prepared = true,
        );
        await detect(tester);
        expect(validating, isTrue);
        popup.params.onCloseWindow!(popupController);
        await tester.runAsync(() async {
          pending.complete();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        expect(
          services.vault.credential(cloud)?.field('refreshToken'),
          rejected ? isNull : refreshToken,
        );
        expect(
          find.byType(WebLoginPage),
          rejected ? findsOneWidget : findsNothing,
        );
        if (rejected) expect(find.text('授权信息已过期，请重新登录'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  WebResourceRequest request(bool mainFrame) => WebResourceRequest(
    url: WebUri('https://example.invalid/private-login?token=private-token'),
    isForMainFrame: mainFrame,
  );

  Json ctfileSuccess() => {
    'source': 'ctfile-captcha',
    'type': 'altcha',
    'event': 'success',
    'token': 'verified-widget-proof-0123456789',
  };

  Future<void> openCtfileVerification(
    WidgetTester tester,
    CtfileCaptchaChallenge challenge,
    void Function(CtfileCaptchaProof?) result,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result(
                await Navigator.push<CtfileCaptchaProof>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CtfileVerificationPage(services, challenge),
                  ),
                ),
              ),
              child: const Text('城通验证测试'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('城通验证测试'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Ctfile captcha accepts Android wrappers for the same official WebView',
    (tester) async {
      final challenge = CtfileCaptchaChallenge('altcha');
      CtfileCaptchaProof? result;
      await openCtfileVerification(
        tester,
        challenge,
        (proof) => result = proof,
      );
      final view = platform.views.last;
      expect(view.params.initialSettings!.incognito, isTrue);
      expect(view.params.initialSettings!.saveFormData, isFalse);
      expect(
        view.params.initialSettings!.userAgent,
        WebLoginTarget.desktopUserAgent,
      );
      expect(view.params.initialUserScripts!.single.forMainFrameOnly, isTrue);
      final native = _CtfileController(301, challenge);
      final created = view.controllerFromPlatform<InAppWebViewController>(
        native,
      );
      final loaded = view.controllerFromPlatform<InAppWebViewController>(
        native,
      );
      view.params.onWebViewCreated!(created);
      expect(
        await view.params.shouldOverrideUrlLoading!(
          loaded,
          NavigationAction(
            request: URLRequest(url: WebUri('https://untrusted.invalid/')),
            isForMainFrame: true,
          ),
        ),
        NavigationActionPolicy.CANCEL,
      );
      view.params.onLoadStop!(loaded, native.url);
      await tester.pump();
      native.message = {...ctfileSuccess(), 'type': 'turnstile'};
      await tester.pump(const Duration(milliseconds: 350));
      expect(result, isNull);
      native.message = ctfileSuccess();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(result!.fields.keys, ['altcha_token']);
      expect(find.byType(CtfileVerificationPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Ctfile ignores a proof after navigating away during capture', (
    tester,
  ) async {
    final challenge = CtfileCaptchaChallenge('altcha');
    CtfileCaptchaProof? result;
    await openCtfileVerification(tester, challenge, (proof) => result = proof);
    final native = _CtfileController(302, challenge)
      ..navigateDuringCapture = true
      ..message = ctfileSuccess();
    final (view, web) = attach(302, instance: native);
    view.params.onLoadStop!(web, native.url);
    await tester.pump();
    expect(result, isNull);
    expect(find.byType(CtfileVerificationPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(result, isNull);
    final captures = native.captures;
    await tester.pump(const Duration(seconds: 1));
    expect(native.captures, captures);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Ctfile refresh discards a late old document proof and cancellation stops capture',
    (tester) async {
      final challenge = CtfileCaptchaChallenge('altcha');
      CtfileCaptchaProof? result;
      await openCtfileVerification(
        tester,
        challenge,
        (proof) => result = proof,
      );
      final oldNative = _CtfileController(303, challenge)
        ..pending = Completer<dynamic>();
      final (oldView, oldWeb) = attach(303, instance: oldNative);
      oldView.params.onLoadStop!(oldWeb, oldNative.url);
      await tester.pump();
      expect(oldNative.captures, 1);
      await tester.tap(find.byKey(const ValueKey('ctfile-captcha-refresh')));
      await tester.pumpAndSettle();
      final native = _CtfileController(304, challenge);
      final (view, web) = attach(304, instance: native);
      view.params.onLoadStop!(web, native.url);
      oldNative.pending!.complete(jsonEncode(ctfileSuccess()));
      await tester.pump();
      expect(result, isNull);
      native.pending = Completer<dynamic>();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pageBack();
      await tester.pumpAndSettle();
      native.pending!.complete(jsonEncode(ctfileSuccess()));
      await tester.pump();
      expect(result, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Guangya desktop verification accepts only its matching main-frame callback',
    (tester) async {
      final challenge = GuangyaCaptchaChallenge(
        'https://captcha.guangyapan.com/verify',
      );
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          GuangyaVerificationPage(services, challenge),
                    ),
                  );
                },
                child: const Text('验证测试'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('验证测试'));
      await tester.pumpAndSettle();
      final view = platform.views.last;
      expect(
        view.params.initialSettings!.userAgent,
        WebLoginTarget.desktopUserAgent,
      );
      expect(
        view.params.initialSettings!.preferredContentMode,
        UserPreferredContentMode.DESKTOP,
      );
      final controller = view.controllerFromPlatform<InAppWebViewController>(
        _Controller(201),
      );
      final callback = Uri.parse(GuangyaCaptchaChallenge.callback).replace(
        queryParameters: {
          'asterlink_captcha': '1',
          'state': challenge.state,
          'captcha_token': 'verified-captcha-token-0123456789',
        },
      );
      Future<NavigationActionPolicy?> navigate(Uri uri, bool main) =>
          view.params.shouldOverrideUrlLoading!(
            controller,
            NavigationAction(
              request: URLRequest(url: WebUri.uri(uri)),
              isForMainFrame: main,
            ),
          );
      expect(
        await navigate(callback.replace(host: 'untrusted.invalid'), true),
        NavigationActionPolicy.CANCEL,
      );
      await navigate(callback, false);
      await navigate(
        callback.replace(
          queryParameters: {
            ...callback.queryParameters,
            'state': 'wrong-attempt',
          },
        ),
        true,
      );
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(GuangyaVerificationPage), findsOneWidget);
      expect(await navigate(callback, true), NavigationActionPolicy.CANCEL);
      await tester.pumpAndSettle();
      expect(result, 'verified-captcha-token-0123456789');
      expect(find.byType(GuangyaVerificationPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Aliyun waits for a clean browser, submits once, then validates and saves tokens',
    (tester) async {
      final target = WebLoginTarget.targets[CloudPlatform.aliyun]!;
      final attempt = AliyunWebPassword(
        'fixture-user',
        'private-fixture-password',
      );
      var validations = 0;
      services.login.webAuthenticators[CloudPlatform.aliyun] =
          (credential) async {
            validations++;
            return LoginResult(credential, const CloudAccount('阿里登录测试'));
          };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        WebLoginPage(services, target, passwordLogin: attempt),
                  ),
                ),
                child: const Text('登录测试'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('登录测试'));
      await tester.pumpAndSettle();
      final native = _PasswordController(attempt);
      final (view, controller) = attach(200, instance: native);
      for (final script in view.params.initialUserScripts!) {
        expect(script.source, isNot(contains('private-fixture-password')));
      }
      Future<void> loaded() async {
        await tester.runAsync(() async {
          view.params.onLoadStop!(controller, WebUri(target.url));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
      }

      await loaded();
      expect(native.reloads, 1);
      expect(native.submissions, 0);
      expect(attempt.pending, isTrue);
      native.formReady = false;
      native.tokenReady = true;
      await loaded();
      expect(validations, 0);
      expect(native.submissions, 0);
      native.formReady = true;
      native.tokenReady = false;
      await loaded();
      expect(native.submissions, 1);
      expect(attempt.pending, isFalse);
      expect(validations, 0);
      await tester.tap(find.text('检测登录'));
      await tester.pumpAndSettle();
      expect(native.submissions, 1);
      native.tokenReady = true;
      await tester.runAsync(() async {
        await tester.tap(find.text('检测登录'));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(validations, 1);
      expect(
        services.vault.credential(CloudPlatform.aliyun)!.field('refreshToken'),
        refreshToken,
      );
      expect(find.byType(WebLoginPage), findsNothing);
      expect(native.submissions, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final p in [CloudPlatform.aliyun, CloudPlatform.guangya]) {
    for (final navigate in [false, true]) {
      testWidgets(
        '${p.key} captures token storage with navigation checks: redirect=$navigate',
        (tester) async {
          try {
            var validations = 0;
            services.login.webAuthenticators[p] = (credential) async {
              validations++;
              expect(credential.field('accessToken'), accessToken);
              expect(credential.field('refreshToken'), refreshToken);
              return LoginResult(credential, const CloudAccount('网页登录测试'));
            };
            final target = WebLoginTarget.targets[p]!;
            await tester.pumpWidget(
              MaterialApp(
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => WebLoginPage(services, target),
                        ),
                      ),
                      child: const Text('登录测试'),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('登录测试'));
            await tester.pumpAndSettle();
            final native = _StorageController(
              100,
              target,
              navigateDuringRead: navigate,
            );
            final (view, controller) = attach(100, instance: native);
            await tester.runAsync(() async {
              view.params.onLoadStop!(controller, WebUri(target.url));
              await Future<void>.delayed(const Duration(milliseconds: 20));
            });
            await tester.pumpAndSettle();
            expect(native.clears, 1);
            expect(native.reloads, 1);
            expect(validations, 0);
            await tester.runAsync(() async {
              view.params.onLoadStop!(controller, WebUri(target.url));
              await Future<void>.delayed(const Duration(milliseconds: 20));
            });
            await tester.pumpAndSettle();
            expect(native.reads, 1);
            expect(validations, navigate ? 0 : 1);
            expect(
              services.vault.credential(p)?.field('refreshToken'),
              navigate ? isNull : refreshToken,
            );
            expect(native.clears, 1);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
          }
        },
      );
    }
  }

  testWidgets('new account login starts with an empty browser cookie jar', (
    tester,
  ) async {
    await render(tester);
    expect(platform.cookies.deleteAllCalls, 1);
    expect(platform.views.single.params.initialSettings!.incognito, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cookie cleanup failure does not open a reused account session', (
    tester,
  ) async {
    platform.cookies.failClear = true;
    await render(tester);
    expect(find.text('重试'), findsOneWidget);
    expect(platform.views, isEmpty);
    expect(
      log.entries().any(
        (entry) => entry.event == 'web_login.initialize_failed',
      ),
      isTrue,
    );
    platform.cookies.failClear = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Baidu login records each phase without saving credentials', (
    tester,
  ) async {
    const cloud = CloudPlatform.baidu;
    services.login.webAuthenticators[cloud] = (credential) async =>
        LoginResult(credential, const CloudAccount('百度测试'));
    await openLogin(tester, cloud);
    attach(501);
    for (final url in WebLoginTarget.targets[cloud]!.cookieUrls(null)) {
      platform.cookies.values[url] = [
        Cookie(name: 'BDUSS', value: 'fixture-private-bduss' * 10),
      ];
    }
    await detect(tester);
    expect(find.byType(WebLoginPage), findsNothing);
    final entries = log.entries();
    final events = entries.map((entry) => entry.event).toList();
    expect(
      events,
      containsAll([
        'web_login.poll_started',
        'web_login.browser_state_read_started',
        'web_login.browser_state_read_completed',
        'web_login.validation_started',
        'web_login.validation_succeeded',
        'web_login.cookie_cleanup_completed',
        'web_login.close_requested',
        'web_login.closed',
      ]),
    );
    final read = entries.firstWhere(
      (entry) => entry.event == 'web_login.browser_state_read_completed',
    );
    expect(read.data['fields'], containsPair('hasLoginSession', true));
    expect(read.data['fields'], containsPair('poll', 1));
    expect(
      entries.map((entry) => entry.detail).join('\n'),
      isNot(contains('private-bduss')),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Web callbacks record typed errors without page or response data',
    (tester) async {
      await render(tester);
      final (view, controller) = attach(1);
      view.params.onLoadStart!(controller, request(true).url);
      view.params.onReceivedError!(
        controller,
        request(false),
        WebResourceError(
          type: WebResourceErrorType.HOST_LOOKUP,
          description: 'private-error-body',
        ),
      );
      view.params.onReceivedHttpError!(
        controller,
        request(true),
        WebResourceResponse(statusCode: 503, reasonPhrase: 'private-response'),
      );
      await tester.pump();
      expect(find.text('登录页面暂时不可用，可刷新后重试'), findsOneWidget);
      final resource = log.entries().singleWhere(
        (entry) => entry.event == 'web_login.resource_failed',
      );
      final http = log.entries().singleWhere(
        (entry) => entry.event == 'web_login.http_failed',
      );
      expect(resource.level, 'warning');
      expect(http.level, 'error');
      expect(http.data['fields'], containsPair('httpStatus', 503));
      expect(
        log.entries().map((entry) => entry.detail).join(),
        isNot(contains('private-')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Renderer retry ignores old callbacks and unblocks a pending read',
    (tester) async {
      await render(tester);
      final (oldView, oldController) = attach(1);
      final oldRead = Completer<List<Cookie>>();
      platform.cookies.pending[oldController.platform] = oldRead;
      oldView.params.onLoadStop!(oldController, request(true).url);
      await tester.pump();
      expect(platform.cookies.reads[oldController.platform], 1);
      expect(oldView.params.initialSettings!.useOnRenderProcessGone, isTrue);
      oldView.params.onRenderProcessGone!(
        oldController,
        RenderProcessGoneDetail(didCrash: false),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InAppWebView), findsNothing);
      expect(platform.views.any((view) => view.disposed), isTrue);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      final (newView, newController) = attach(2);
      final newRead = Completer<List<Cookie>>();
      platform.cookies.pending[newController.platform] = newRead;
      newView.params.onLoadStop!(newController, request(true).url);
      await tester.pump();
      expect(platform.cookies.reads[newController.platform], 1);

      oldView.params.onReceivedHttpError!(
        oldController,
        request(true),
        WebResourceResponse(statusCode: 401),
      );
      oldView.params.onProgressChanged!(oldController, 99);
      oldRead.complete([Cookie(name: '__puus', value: 'private-old-cookie')]);
      await tester.pump();
      newView.params.onLoadStop!(newController, request(true).url);
      await tester.pump();
      expect(platform.cookies.reads[newController.platform], 1);
      expect(services.vault.credential(CloudPlatform.quark), isNull);
      expect(
        log.entries().where((entry) => entry.event == 'web_login.http_failed'),
        isEmpty,
      );
      final progress = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(progress.value, 0);

      newRead.complete([]);
      await tester.pump();
      newView.params.onLoadStop!(newController, request(true).url);
      await tester.pump();
      expect(platform.cookies.reads[newController.platform], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Cookie read failure is distinguished from credential validation',
    (tester) async {
      await render(tester);
      final (view, controller) = attach(1);
      platform.cookies.failRead = true;
      view.params.onLoadStop!(controller, request(true).url);
      await tester.pump();
      final entry = log.entries().singleWhere(
        (entry) => entry.event == 'web_login.credential_read_failed',
      );
      expect(entry.data['fields'], containsPair('stage', 'read_credentials'));
      expect(entry.detail, isNot(contains('private-read-secret')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Initialization failure records its stage and refresh retries', (
    tester,
  ) async {
    services.failInitialization = true;
    await render(tester);
    expect(find.text('重试'), findsOneWidget);
    expect(
      log.entries().where(
        (entry) => entry.event == 'web_login.initialize_failed',
      ),
      hasLength(1),
    );
    services.failInitialization = false;
    await tester.tap(find.byTooltip('刷新网页'));
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
