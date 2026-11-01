import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/cloud_accounts_page.dart';
import 'package:asterlink/ui/github_login_page.dart';
import 'package:asterlink/ui/loading_indicator.dart';
import 'package:asterlink/ui/login_page.dart';
import 'support.dart';

// Keep the real state mutation and notification behavior while controlling the
// storage wait or failure that precedes an account-slot reservation.
class _ControlledStateStore extends ChangeNotifier implements StateStore {
  _ControlledStateStore(this.delegate) {
    delegate.addListener(notifyListeners);
  }
  final StateStore delegate;
  final _gate = AsyncGate();
  Completer<void>? nextWrite;
  bool failNextWrite = false;
  int changes = 0;

  @override
  Json get data => delegate.data;
  @override
  File? get file => delegate.file;
  @override
  Future<T> change<T>(T Function(Json draft) edit, {String? recoveryPassword}) {
    changes++;
    return _gate.run(() async {
      final pending = nextWrite;
      nextWrite = null;
      await pending?.future;
      if (failNextWrite) {
        failNextWrite = false;
        throw const FileSystemException('Fixture storage is unavailable');
      }
      return delegate.change(edit, recoveryPassword: recoveryPassword);
    });
  }

  @override
  Future<void> put(String key, Object? value) => change((draft) {
    draft[key] = value;
  });
  @override
  Future<void> flush() => _gate.run(delegate.flush);
  @override
  Future<void> protectRecovery(String password) =>
      delegate.protectRecovery(password);
  @override
  void dispose() {
    delegate.removeListener(notifyListeners);
    delegate.dispose();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platform = CloudPlatform.tianyi;
  final add = find.byKey(ValueKey('account-add-${platform.key}'));
  late Directory directory;
  late _ControlledStateStore store;
  late AppServices services;
  late String previous;

  Future<void> render(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 864);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    directory = Directory.systemTemp.createTempSync('asterlink-login-entry-');
    store = _ControlledStateStore(StateStore.memory());
    services = AppServices(
      store: store,
      dataDirectory: directory,
      cacheDirectory: Directory('${directory.path}/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('${directory.path}/saved')),
      http: FakeHttp(),
      controlEnabled: false,
      platformFeatures: false,
    );
    await services.vault.putCredential(
      platform,
      Credential('原有账号', {'primary': 'fixture-cookie'}, updatedAt: 1),
    );
    await services.initialize();
    previous = services.vault.activeAccountId(platform)!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final closing = services.close().whenComplete(() => closed = true);
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue, reason: 'Fixture cleanup must finish');
      await closing;
      store.dispose();
      directory.deleteSync(recursive: true);
    });
    await tester.pumpWidget(AsterLinkApp(services, initialTab: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账号管理'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      add,
      180,
      scrollable: find.descendant(
        of: find.byType(CloudAccountsPage),
        matching: find.byType(Scrollable),
      ),
    );
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  void expectOriginalAccount() {
    expect(services.vault.activeAccountId(platform), previous);
    expect(
      services.vault.credentialFor(platform, previous)?.primary,
      'fixture-cookie',
    );
    expect(services.vault.profiles(platform).single.id, previous);
  }

  testWidgets(
    'Adding opens immediately while storage is waiting',
    (tester) async {
      await render(tester);
      final wait = Completer<void>();
      store.nextWrite = wait;
      final changes = store.changes;
      addTearDown(() {
        if (!wait.isCompleted) wait.complete();
      });
      await tester.tap(add);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('天翼登录'), findsOneWidget);
      expect(find.text('正在准备登录…'), findsOneWidget);
      expect(find.byType(AppLoadingIndicator), findsOneWidget);
      expect(find.byType(NativePasswordLoginPage), findsNothing);

      // A queued second click must not reserve another account or push a route.
      tester
          .widget<TextButton>(
            find.byKey(
              ValueKey('account-add-${platform.key}'),
              skipOffstage: false,
            ),
          )
          .onPressed!();
      await tester.pump();
      expect(store.changes, changes + 1);

      // Rebuilding the application during the wait must preserve this route.
      await store.delegate.put('loginEntryFixtureRebuild', true);
      await tester.pump();
      expect(find.text('正在准备登录…'), findsOneWidget);
      wait.complete();
      await tester.pumpAndSettle();
      final login = tester.widget<NativePasswordLoginPage>(
        find.byType(NativePasswordLoginPage),
      );
      expect(login.accountId, isNot(previous));
      expectOriginalAccount();
      await back(tester);
      expect(find.byType(CloudAccountsPage), findsOneWidget);
      expect(store.data.obj('cloudAccounts').obj(platform.key), hasLength(1));
      expectOriginalAccount();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Account storage failure is visible and can be retried',
    (tester) async {
      await render(tester);
      store.failNextWrite = true;
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('无法打开登录'), findsOneWidget);
      expect(find.text('文件读写失败，请检查目录权限和可用空间'), findsOneWidget);
      expect(find.byType(NativePasswordLoginPage), findsNothing);
      expectOriginalAccount();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.byType(NativePasswordLoginPage), findsOneWidget);
      expectOriginalAccount();
      await back(tester);
      expect(store.data.obj('cloudAccounts').obj(platform.key), hasLength(1));
      expectOriginalAccount();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Leaving while storage waits cleans up the late reservation',
    (tester) async {
      await render(tester);
      final wait = Completer<void>();
      store.nextWrite = wait;
      addTearDown(() {
        if (!wait.isCompleted) wait.complete();
      });
      await tester.tap(add);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await back(tester);
      expect(find.byType(CloudAccountsPage), findsOneWidget);
      wait.complete();
      await tester.pumpAndSettle();
      expect(find.byType(NativePasswordLoginPage), findsNothing);
      expect(store.data.obj('cloudAccounts').obj(platform.key), hasLength(1));
      expectOriginalAccount();
      // A fresh click works after cancellation instead of keeping a stale lock.
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(NativePasswordLoginPage), findsOneWidget);
      await back(tester);
      expect(store.data.obj('cloudAccounts').obj(platform.key), hasLength(1));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Every account-manager add button opens its provider login',
    (tester) async {
      await render(tester);
      final scrollable = find.descendant(
        of: find.byType(CloudAccountsPage),
        matching: find.byType(Scrollable),
      );
      await tester.drag(scrollable, const Offset(0, 2400));
      await tester.pumpAndSettle();
      for (final provider in CloudPlatform.values) {
        final target = find.byKey(ValueKey('account-add-${provider.key}'));
        await tester.scrollUntilVisible(target, 160, scrollable: scrollable);
        await tester.tap(target);
        await tester.pumpAndSettle();
        final String? owner;
        if (provider == CloudPlatform.github) {
          owner = tester
              .widget<GitHubLoginPage>(find.byType(GitHubLoginPage))
              .accountId;
        } else if ({
          CloudPlatform.pan115,
          CloudPlatform.uc,
          CloudPlatform.c139,
          CloudPlatform.weiyun,
        }.contains(provider)) {
          final login = tester.widget<WebLoginPage>(find.byType(WebLoginPage));
          expect(login.target.platform, provider);
          owner = login.accountId;
        } else {
          final login = tester.widget<PasswordLoginFlow>(
            find.byType(PasswordLoginFlow),
          );
          expect(login.platform, provider);
          owner = login.accountId;
        }
        expect(owner, isNotNull, reason: provider.label);
        expect(owner, isNot(previous), reason: provider.label);
        expectOriginalAccount();
        await back(tester);
        expect(find.byType(CloudAccountsPage), findsOneWidget);
        expect(
          store.data.obj('cloudAccounts').obj(provider.key).containsKey(owner),
          isFalse,
          reason: provider.label,
        );
        expectOriginalAccount();
        expect(tester.takeException(), isNull, reason: provider.label);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Encrypted storage failure and retry retain existing accounts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 864);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      late Directory diskDirectory;
      late AppServices diskServices;
      final key = CryptoBox.random(32);
      await tester.runAsync(() async {
        diskDirectory = await Directory.systemTemp.createTemp(
          'asterlink-login-entry-disk-',
        );
        final disk = await StateStore.open(diskDirectory, testKey: key);
        diskServices = AppServices(
          store: disk,
          dataDirectory: diskDirectory,
          cacheDirectory: Directory('${diskDirectory.path}/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('${diskDirectory.path}/saved')),
          http: FakeHttp(),
          controlEnabled: false,
          platformFeatures: false,
        );
        await diskServices.vault.putCredential(
          platform,
          Credential('原有账号', {'primary': 'fixture-cookie'}, updatedAt: 1),
        );
        await diskServices.initialize();
      });
      final diskStore = diskServices.store;
      final original = diskServices.vault.activeAccountId(platform)!;
      final blockedWrite = Directory('${diskStore.file!.path}.tmp');
      Future<void> finishStorageRoute(Finder ready) async {
        // Encrypted disk I/O runs outside the test's fake clock. Wait for its
        // actual route state before settling the animated loading indicator.
        for (var attempt = 0; attempt < 100 && ready.evaluate().isEmpty; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(ready, findsOneWidget);
        await tester.pumpAndSettle();
      }
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (await blockedWrite.exists()) await blockedWrite.delete();
          await diskServices.close();
          diskStore.dispose();
          await diskDirectory.delete(recursive: true);
        });
      });
      await tester.pumpWidget(AsterLinkApp(diskServices, initialTab: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('账号管理'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        add,
        180,
        scrollable: find.descendant(
          of: find.byType(CloudAccountsPage),
          matching: find.byType(Scrollable),
        ),
      );
      // Only this temporary fixture's write path is obstructed. The existing
      // encrypted snapshot remains untouched when reserving the new slot fails.
      await tester.runAsync(() async {
        await blockedWrite.create();
        await tester.tap(add);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await finishStorageRoute(find.text('无法打开登录'));
      expect(find.text('文件读写失败，请检查目录权限和可用空间'), findsOneWidget);
      expect(diskServices.vault.activeAccountId(platform), original);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await blockedWrite.delete();
        await tester.tap(find.text('重试'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await finishStorageRoute(find.byType(NativePasswordLoginPage));
      final login = tester.widget<NativePasswordLoginPage>(
        find.byType(NativePasswordLoginPage),
      );
      final owner = login.accountId;
      expect(owner, isNotNull);
      expect(owner, isNot(original));
      await tester.runAsync(() async {
        await tester.binding.handlePopRoute();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await diskStore.flush();
        final reopened = await StateStore.open(diskDirectory, testKey: key);
        try {
          expect(Vault(reopened).activeAccountId(platform), original);
          expect(Vault(reopened).profiles(platform).single.id, original);
          expect(
            reopened.data
                .obj('cloudAccounts')
                .obj(platform.key)
                .containsKey(owner),
            isFalse,
          );
        } finally {
          reopened.dispose();
        }
      });
      await tester.pumpAndSettle();
      expect(find.byType(CloudAccountsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
