import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/cloud_page.dart';
import 'package:asterlink/ui/guangya_sms_login_page.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/ui/wopan_sms_login_page.dart';
import 'browser_test_support.dart';
import 'token_cloud_support.dart';

class _AliSpaces extends BrowserTestConnector {
  _AliSpaces() : super(CloudPlatform.aliyun);
  final drivesRead = <String>[];
  @override
  Future<List<CloudSpace>> personalSpaces(Credential c) async => const [
    CloudSpace('resource', '资源库'),
    CloudSpace('backup', '备份盘'),
    CloudSpace('album', '相册'),
  ];
  @override
  Future<BrowseSession> openPersonalSpace(
    CloudSpace space,
    Credential c,
  ) async => tokenPersonal(platform, drive: space.id);
  @override
  Future<BrowseSession> openPersonal(Credential c) async =>
      tokenPersonal(platform);
  @override
  String destinationId(BrowseSession s, String id) =>
      'aliyun:${s.personalSpaceId}:$id';
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    drivesRead.add(s.personalSpaceId);
    return super.list(s, parent, c);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final p in [
    CloudPlatform.aliyun,
    CloudPlatform.guangya,
    CloudPlatform.wopan,
    CloudPlatform.ilanzou,
  ]) {
    testWidgets(
      '${p.key} home entry opens its own login and cancellation removes the empty account',
      (tester) async {
        final fixture = await BrowserUiFixture.create(platform: p);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        try {
          await fixture.services.vault.removeCredential(p);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1100, 780);
          await tester.pumpWidget(
            MaterialApp(home: Scaffold(body: CloudPage(fixture.services))),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(p.label),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text(p.label));
          await tester.pumpAndSettle();
          if (p == CloudPlatform.guangya || p == CloudPlatform.wopan) {
            expect(find.text('手机号登录'), findsOneWidget);
            expect(
              find.byKey(ValueKey('${p.name}-sms-mobile')),
              findsOneWidget,
            );
            expect(find.byKey(ValueKey('${p.name}-sms-code')), findsOneWidget);
          } else {
            expect(find.byType(NativePasswordLoginPage), findsOneWidget);
            expect(
              tester
                  .widget<NativePasswordLoginPage>(
                    find.byType(NativePasswordLoginPage),
                  )
                  .platform,
              p,
            );
            expect(
              find.byKey(const ValueKey('native-login-username')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('native-login-password')),
              findsOneWidget,
            );
          }
          await tester.tap(find.byKey(const ValueKey('native-login-web')));
          await tester.pumpAndSettle();
          expect(find.byType(WebLoginPage), findsOneWidget);
          expect(
            tester
                .widget<WebLoginPage>(find.byType(WebLoginPage))
                .target
                .platform,
            p,
          );
          await tester.tap(find.byKey(const ValueKey('web-login-password')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('native-login-manual')));
          await tester.pumpAndSettle();
          expect(find.byType(ManualLoginPage), findsOneWidget);
          expect(
            tester
                .widget<ManualLoginPage>(find.byType(ManualLoginPage))
                .platform,
            p,
          );
          await tester.tap(find.byKey(const ValueKey('manual-login-password')));
          await tester.pumpAndSettle();
          expect(
            find.byType(switch (p) {
              CloudPlatform.guangya => GuangyaSmsLoginPage,
              CloudPlatform.wopan => WopanSmsLoginPage,
              _ => NativePasswordLoginPage,
            }),
            findsOneWidget,
          );
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(fixture.services.vault.profiles(p), isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }
      },
    );
    testWidgets(
      '${p.key} manual entry saves into the account created by the login flow',
      (tester) async {
        final fixture = await BrowserUiFixture.create(platform: p);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        try {
          await fixture.services.vault.removeCredential(p);
          fixture.services.login.webAuthenticators[p] = (credential) async =>
              LoginResult(credential, const CloudAccount('手动登录测试'));
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(393, 864);
          await tester.pumpWidget(
            MaterialApp(home: Scaffold(body: CloudPage(fixture.services))),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(p.label),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text(p.label));
          await tester.pumpAndSettle();
          final owner = tester
              .widget<PasswordLoginFlow>(find.byType(PasswordLoginFlow))
              .accountId;
          expect(owner, isNotNull);
          await tester.ensureVisible(
            find.byKey(const ValueKey('native-login-manual')),
          );
          await tester.tap(find.byKey(const ValueKey('native-login-manual')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextField),
            jsonEncode(
              p == CloudPlatform.ilanzou
                  ? {'appToken': accessToken, 'uuid': 'fixture-device-12345'}
                  : {
                      'access_token': accessToken,
                      'refresh_token': refreshToken,
                    },
            ),
          );
          await tester.tap(find.text('验证并保存'));
          await tester.pumpAndSettle();
          expect(find.byType(PasswordLoginFlow), findsNothing);
          expect(fixture.services.vault.activeAccountId(p), owner);
          expect(
            fixture.services.vault
                .credentialFor(p, owner)!
                .field(
                  p == CloudPlatform.ilanzou ? 'accessToken' : 'refreshToken',
                ),
            p == CloudPlatform.ilanzou ? accessToken : refreshToken,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets(
    'Aliyun submits to a one-use official form and clears it when switching methods',
    (tester) async {
      final fixture = await BrowserUiFixture.create(
        platform: CloudPlatform.aliyun,
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await fixture.services.vault.removeCredential(CloudPlatform.aliyun);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(393, 864);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: CloudPage(fixture.services))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(CloudPlatform.aliyun.label));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('native-login-username')),
          '12345678901',
        );
        await tester.enterText(
          find.byKey(const ValueKey('native-login-password')),
          ' fixture-password ',
        );
        await tester.tap(find.byKey(const ValueKey('native-login-submit')));
        await tester.pumpAndSettle();
        final page = tester.widget<WebLoginPage>(find.byType(WebLoginPage));
        final attempt = page.passwordLogin!;
        expect(attempt.pending, isTrue);
        expect(attempt.bootstrapScript, isNot(contains('fixture-password')));
        expect(fixture.services.vault.credential(CloudPlatform.aliyun), isNull);
        await tester.tap(find.byKey(const ValueKey('web-login-password')));
        await tester.pumpAndSettle();
        expect(attempt.pending, isFalse);
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('native-login-password')),
              )
              .controller!
              .text,
          isEmpty,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(fixture.services.vault.profiles(CloudPlatform.aliyun), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    },
  );

  for (final size in [const Size(393, 864), const Size(1100, 780)]) {
    testWidgets(
      'Aliyun switches drives and target selection carries the drive at $size',
      (tester) async {
        final fixture = await BrowserUiFixture.create(
          platform: CloudPlatform.aliyun,
        );
        final connector = _AliSpaces();
        fixture.services.cloud.connectors[CloudPlatform.aliyun] = connector;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        try {
          await fixture.render(
            tester,
            session: tokenPersonal(CloudPlatform.aliyun),
            size: size,
          );
          await tester.tap(find.text('假期相册'));
          await tester.pumpAndSettle();
          await tester.longPress(find.text('旧目录视频.mp4'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('personal-space-selector')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('备份盘'));
          await tester.pumpAndSettle();
          expect(connector.drivesRead.last, 'backup');
          expect(find.text('旧目录视频.mp4'), findsNothing);
          expect(find.text('已选 1 项'), findsNothing);
          expect(find.text('假期相册'), findsOneWidget);
          expect(find.text('备份盘 ▾'), findsOneWidget);

          await tester.tap(
            find.byKey(const ValueKey('personal-space-selector')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('相册'));
          await tester.pumpAndSettle();
          expect(connector.drivesRead.last, 'album');
          expect(find.text('相册 ▾'), findsOneWidget);
          expect(find.text('假期相册'), findsOneWidget);

          await tester.pumpWidget(const SizedBox.shrink());
          String? chosen;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      chosen = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BrowserPage(
                            fixture.services,
                            tokenPersonal(CloudPlatform.aliyun),
                            picking: true,
                          ),
                        ),
                      );
                    },
                    child: const Text('选择目标'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('选择目标'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('personal-space-selector')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('备份盘'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('假期相册'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('选择“假期相册”'));
          await tester.pumpAndSettle();
          expect(chosen, 'aliyun:backup:photos');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }
      },
    );
  }
}
