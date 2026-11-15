import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/auth.dart';
import 'native_login_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Tianyi auto-login failure marks the cloud card even when triggered by browsing',
    () async {
      final fixture = TianyiLoginFixture(LoginTestKey());
      final initial = (await fixture.submit()).credential;
      final services = AppServices(
        controlEnabled: false,
        store: fixture.store,
        dataDirectory: Directory('services-fixture'),
        cacheDirectory: Directory('services-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('services-fixture/saved')),
        platformFeatures: false,
        http: fixture.http,
      );
      addTearDown(services.close);
      await services.initialize();
      await until(() => services.accounts[CloudPlatform.tianyi]?.total == 1000);
      fixture.override = (r) => r.uri.path.endsWith('/listFiles.action')
          ? jsonResponse({'errorCode': 'InvalidSessionKey'}, 400)
          : null;
      fixture.signIn = {'result': -69};
      await expectLater(
        services.cloud
            .connector(CloudPlatform.tianyi)
            .list(
              const BrowseSession(
                platform: CloudPlatform.tianyi,
                mode: BrowseMode.personal,
                title: 'fixture',
                rootId: '-11',
              ),
              '-11',
              initial,
            ),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(services.accountNeedsLogin, contains(CloudPlatform.tianyi));
      expect(services.accountErrors[CloudPlatform.tianyi], contains('自动登录失败'));
      expect(services.accounts[CloudPlatform.tianyi], isNull);
      expect(
        services.vault.credential(CloudPlatform.tianyi)!.updatedAt,
        initial.updatedAt,
      );
      final count = fixture.http.calls.length;
      await services.refreshAccount(CloudPlatform.tianyi);
      expect(fixture.http.calls.length, count);
      await services.login.remove(CloudPlatform.tianyi);
      expect(services.accountNeedsLogin, isEmpty);
    },
  );

  test(
    '123 auto-login failure outside a quota request marks its cloud card for manual login',
    () async {
      const platform = CloudPlatform.pan123;
      final initial = Credential('fixture', {
        'primary': 'fixture-phone',
        'secondary': 'fixture-password',
        'authType': 'password',
        'accessToken': 'old-token',
      }, updatedAt: 42);
      var expired = false;
      final store = StateStore.memory({
        'credentials': {platform.key: initial.toJson()},
      });
      final http = FakeHttp(
        (r) => expired
            ? jsonResponse({'code': 401})
            : jsonResponse({
                'code': 0,
                'data': {
                  'Nickname': 'fixture',
                  'SpaceUsed': 2,
                  'SpacePermanent': 100,
                },
              }),
      );
      final services = AppServices(
        controlEnabled: false,
        store: store,
        dataDirectory: Directory('services-fixture'),
        cacheDirectory: Directory('services-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('services-fixture/saved')),
        platformFeatures: false,
        http: http,
      );
      addTearDown(services.close);
      await services.initialize();
      await until(() => services.accounts[platform]?.total == 100);
      expired = true;
      await expectLater(
        services.cloud
            .connector(platform)
            .list(
              const BrowseSession(
                platform: platform,
                mode: BrowseMode.personal,
                title: 'fixture',
                rootId: '0',
              ),
              '0',
              initial,
            ),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(services.accountNeedsLogin, contains(platform));
      expect(services.accountErrors[platform], contains('自动登录失败'));
      expect(services.accounts[platform], isNull);
      expect(services.vault.credential(platform)!.updatedAt, 42);
      final count = http.calls.length;
      await services.refreshAccount(platform);
      expect(http.calls.length, count);
      await services.login.remove(platform);
      expect(services.accountNeedsLogin, isEmpty);
    },
  );

  test(
    'Incomplete mobile login becomes actionable and clears after a valid replacement',
    () async {
      final store = StateStore.memory({
        'credentials': {
          CloudPlatform.c139.key: Credential('old', {
            'primary': 'Os_SSo_Sid=early; RMKEY=early',
          }, updatedAt: 1).toJson(),
        },
      });
      final http = FakeHttp(
        (_) => jsonResponse({
          'code': '0000',
          'data': {'diskSize': 100, 'freeDiskSize': 60},
        }),
      );
      final services = AppServices(
        controlEnabled: false,
        store: store,
        dataDirectory: Directory('services-fixture'),
        cacheDirectory: Directory('services-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('services-fixture/saved')),
        platformFeatures: false,
        http: http,
      );
      addTearDown(services.close);
      await services.initialize();
      await until(
        () => services.accountNeedsLogin.contains(CloudPlatform.c139),
      );
      expect(http.calls, isEmpty);
      expect(services.accountErrors[CloudPlatform.c139], contains('重新网页登录'));
      await services.vault.putCredential(
        CloudPlatform.c139,
        Credential('new', {
          'primary':
              'authorization=Basic%20fixture; skey=fixture; ud_id=domain',
        }, updatedAt: 2),
      );
      await until(
        () => services.accounts[CloudPlatform.c139]?.total == 100 * 1024 * 1024,
      );
      expect(services.accountNeedsLogin, isEmpty);
      expect(services.accountErrors, isEmpty);
      expect(services.accountLoading, isEmpty);
      expect(http.calls.length, 1);
    },
  );

  test(
    'A transient capacity error stays retryable and cannot expose stale quota as current',
    () async {
      var failed = true;
      final store = StateStore.memory({
        'credentials': {
          CloudPlatform.c139.key: Credential('fixture', {
            'authorization': 'Basic fixture',
          }, updatedAt: 1).toJson(),
        },
      });
      final services = AppServices(
        controlEnabled: false,
        store: store,
        dataDirectory: Directory('services-fixture'),
        cacheDirectory: Directory('services-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('services-fixture/saved')),
        platformFeatures: false,
        http: FakeHttp(
          (_) => failed
              ? jsonResponse({'code': '04000013'}, 503)
              : jsonResponse({
                  'code': '0000',
                  'data': {'diskSize': 200, 'freeDiskSize': 100},
                }),
        ),
      );
      addTearDown(services.close);
      await services.initialize();
      await until(() => services.accountErrors.containsKey(CloudPlatform.c139));
      expect(services.accountErrors[CloudPlatform.c139], contains('点击重试'));
      expect(services.accountNeedsLogin, isEmpty);
      failed = false;
      await services.refreshAccount(CloudPlatform.c139);
      expect(services.accounts[CloudPlatform.c139]!.used, 100 * 1024 * 1024);
      expect(services.accountErrors, isEmpty);
    },
  );

  test(
    'Switching accounts during a capacity request refreshes the new account',
    () async {
      final first = Completer<HttpResult>();
      var calls = 0;
      final store = StateStore.memory({
        'credentials': {
          'Quark': Credential('old', {
            'primary': '__pus=old; __puus=old',
          }, updatedAt: 1).toJson(),
        },
      });
      final services = AppServices(
        controlEnabled: false,
        store: store,
        dataDirectory: Directory('services-fixture'),
        cacheDirectory: Directory('services-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('services-fixture/saved')),
        platformFeatures: false,
        http: FakeHttp((request) async {
          calls++;
          if (calls == 1) return first.future;
          expect(request.headers['Cookie'], '__pus=new; __puus=new');
          return jsonResponse({
            'status': 200,
            'data': {
              'nickname': 'new',
              'use_capacity': 20,
              'total_capacity': 200,
            },
          });
        }),
      );
      addTearDown(services.close);
      await services.initialize();
      await until(() => calls == 1);
      await services.vault.putCredential(
        CloudPlatform.quark,
        Credential('new', {'primary': '__pus=new; __puus=new'}, updatedAt: 2),
      );
      first.complete(
        jsonResponse({
          'status': 200,
          'data': {
            'nickname': 'old',
            'use_capacity': 10,
            'total_capacity': 100,
          },
        }),
      );
      await until(
        () => services.accounts[CloudPlatform.quark]?.nickname == 'new',
      );
      expect(calls, 2);
      expect(services.accounts[CloudPlatform.quark]!.total, 200);
      expect(services.accounts[CloudPlatform.quark]!.used, 20);
      expect(services.accountLoading, isEmpty);
    },
  );
}
