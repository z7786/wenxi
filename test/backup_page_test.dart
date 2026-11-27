import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/providers/webdav.dart';
import 'package:asterlink/data/classified_backup.dart';
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/domain/webdav.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/backup_page.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/common.dart';
import 'package:asterlink/ui/webdav_login_page.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/data/http.dart';
import 'support.dart';

class BackupUiConnector extends WebDavConnector {
  BackupUiConnector({super.client});
  @override
  final CloudPlatform platform = CloudPlatform.webdav;
  @override
  Future<BrowseSession> openPersonal(Credential c) async => const BrowseSession(
    platform: CloudPlatform.webdav,
    mode: BrowseMode.personal,
    title: '家庭 NAS',
    rootId: '/',
    metadata: {'webdavRoot': 'https://fixture.example/dav/'},
  );
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async => [
    if (parent == '/')
      const CloudFile(
        id: '/backup',
        name: '备份目录',
        isDirectory: true,
        parentId: '/',
      ),
  ];
  @override
  Future<CloudAccount> account(Credential c) async =>
      const CloudAccount('家庭 NAS');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class BackupUiClient extends WebDavClient {
  bool fail = false;
  List<CloudFile> files = [];
  @override
  Future<List<CloudFile>> list(
    WebDavLocation location,
    String parent, {
    required String username,
    required String password,
    void Function()? guard,
  }) async {
    RequestScope.checkpoint();
    guard?.call();
    if (fail) throw const AppException('测试连接中断');
    return files;
  }
}

class BackupUiPicker extends FileSelectorPlatform {
  XFile? file;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => file;
}

void main() {
  var systemFont = false;
  setUpAll(() async {
    for (final pair in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(pair.$1)..addFont(rootBundle.load(pair.$2))).load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('BackupFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });

  Future<AppServices> render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    bool dark = false,
    Json? data,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('backup-widget-'),
    ))!;
    final services = (await tester.runAsync(
      () async => AppServices(
        store: StateStore.memory(data),
        dataDirectory: root,
        cacheDirectory: Directory('${root.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(root),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
        clipboardReader: () async => null,
      ),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final closing = services.close().then((_) => closed = true);
      for (var i = 0; i < 40 && !closed; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue);
      await closing;
      await tester.runAsync(() => root.delete(recursive: true));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('backup-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            dark ? Brightness.dark : Brightness.light,
            fontFamily: systemFont ? 'BackupFixture' : null,
          ),
          home: BackupPage(services),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return services;
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    final directory = Platform.environment['BACKUP_UI_PREVIEW_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('backup-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$directory/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  for (final fixture in [
    (name: 'phone', size: const Size(393, 864), scale: 1.0, dark: false),
    (
      name: 'phone-large-dark',
      size: const Size(320, 720),
      scale: 1.4,
      dark: true,
    ),
    (name: 'desktop', size: const Size(1280, 900), scale: 1.0, dark: false),
    (
      name: 'landscape-large',
      size: const Size(844, 390),
      scale: 1.4,
      dark: true,
    ),
  ]) {
    testWidgets(
      'backup UI ${fixture.name}: sticky actions, encryption errors and restore',
      (tester) async {
        await render(
          tester,
          size: fixture.size,
          scale: fixture.scale,
          dark: fixture.dark,
        );
        expect(find.text('本地文件'), findsOneWidget);
        expect(find.text('WebDAV 登录密码'), findsNothing);
        expect(
          find.byKey(const Key('backup-primary')).hitTestable(),
          findsOneWidget,
        );
        await screenshot(tester, '${fixture.name}-backup');
        await tester.scrollUntilVisible(
          find.byKey(const Key('backup-password-toggle')),
          180,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('backup-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
          maxScrolls: 50,
        );
        expect(
          find.byKey(const Key('backup-primary')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('backup-password-toggle')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('backup-password')));
        await tester.enterText(find.byKey(const Key('backup-password')), '123');
        await tester.tap(find.byKey(const Key('backup-primary')));
        await tester.pumpAndSettle();
        expect(find.text('备份密码至少需要 6 位'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('backup-password')),
          'valid-password',
        );
        await tester.ensureVisible(
          find.byKey(const Key('backup-confirmation')),
        );
        await tester.enterText(
          find.byKey(const Key('backup-confirmation')),
          'different-password',
        );
        await tester.tap(find.byKey(const Key('backup-primary')));
        await tester.pumpAndSettle();
        expect(find.text('两次输入的备份密码不一致'), findsOneWidget);
        if (fixture.size.height > 700) {
          await tester.ensureVisible(find.byKey(const Key('backup-password')));
          await tester.pumpAndSettle();
          await screenshot(tester, '${fixture.name}-encryption');
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('恢复').first);
        await tester.pumpAndSettle();
        expect(find.text('选择备份并预览'), findsOneWidget);
        expect(find.text('备份密码（至少 6 位）'), findsNothing);
        expect(find.text('先预览，再恢复'), findsOneWidget);
        ScaffoldMessenger.of(
          tester.element(find.byType(BackupPage)),
        ).clearSnackBars();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        await screenshot(tester, '${fixture.name}-restore');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'no categories disables backup; keyboard keeps primary action reachable',
    (tester) async {
      await render(tester, size: const Size(393, 864));
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('backup-primary')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('backup-password-toggle')),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('backup-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const Key('backup-password-toggle')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('backup-password')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('backup-primary')).hitTestable(),
        findsOneWidget,
      );
      final rect = tester.getRect(find.byKey(const Key('backup-primary')));
      expect(rect.bottom, lessThanOrEqualTo(564));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'backup chooses a WebDAV cloud account and saves its directory identity',
    (tester) async {
      final services = await render(tester);
      final connector = services.cloud.connector(CloudPlatform.webdav);
      final fixtureConnector = BackupUiConnector();
      services.cloud.connectors[CloudPlatform.webdav] = fixtureConnector;
      // A remembered fixture requires no password dialog; browsing is synthetic.
      await tester.runAsync(
        () => services.vault.putCredential(
          CloudPlatform.webdav,
          Credential('家庭 NAS', {
            'primary': 'https://fixture.example/dav/',
            'authType': 'webdav',
            'rememberPassword': 'true',
          }),
        ),
      );
      addTearDown(() async {
        services.cloud.connectors[CloudPlatform.webdav] = connector;
        await tester.runAsync(fixtureConnector.close);
      });
      await tester.tap(find.text('网盘').first);
      await tester.pumpAndSettle();
      expect(find.text('选择网盘目录'), findsOneWidget);
      await tester.tap(find.byKey(const Key('backup-primary')));
      await tester.pumpAndSettle();
      expect(find.text('家庭 NAS'), findsOneWidget);
      final accountOption = find.ancestor(
        of: find.text('家庭 NAS'),
        matching: find.byType(SimpleDialogOption),
      );
      expect(
        tester
            .widget<PlatformMark>(
              find.descendant(
                of: accountOption,
                matching: find.byType(PlatformMark),
              ),
            )
            .platform,
        CloudPlatform.webdav,
      );
      await tester.tap(find.text('家庭 NAS'));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsOneWidget);
      await tester.tap(find.text('备份目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择“备份目录”'));
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 20 && !services.store.data.containsKey('backupCloudLocation');
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      final target = services.store.data.obj('backupCloudLocation');
      expect(
        target.str('parent'),
        '/backup',
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '),
      );
      final session = BrowseSession.fromJson(target.obj('session'));
      expect(session.platform, CloudPlatform.webdav);
      expect(
        session.accountId,
        services.vault.activeAccountId(CloudPlatform.webdav),
      );
      expect(session.meta('webdavRoot'), 'https://fixture.example/dav/');
      expect(find.text('立即备份'), findsOneWidget);
      expect(
        tester
            .widget<PlatformMark>(
              find.descendant(
                of: find.byKey(const Key('backup-target')),
                matching: find.byType(PlatformMark),
              ),
            )
            .platform,
        CloudPlatform.webdav,
      );
      await screenshot(tester, 'phone-webdav-target');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'WebDAV connection prefills legacy settings, defaults to temporary password and leaves no cancelled account',
    (tester) async {
      final services = await render(
        tester,
        data: {
          'backupWebDav': {
            'url': 'https://fixture.example/dav/',
            'username': 'user',
          },
        },
      );
      final original = services.cloud.connector(CloudPlatform.webdav);
      final connector = WebDavConnector(client: BackupUiClient());
      services.cloud.connectors[CloudPlatform.webdav] = connector;
      addTearDown(() async {
        services.cloud.connectors[CloudPlatform.webdav] = original;
        await tester.runAsync(connector.close);
      });
      final context = tester.element(find.byType(BackupPage));
      await tester.runAsync(() async {
        unawaited(
          openLogin(context, services, CloudPlatform.webdav, addAccount: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.byType(WebDavLoginPage), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('webdav-url')))
            .controller!
            .text,
        'https://fixture.example/dav/',
      );
      expect(find.text('密码仅在本次运行中使用，重启后需重新输入'), findsOneWidget);
      await tester.pageBack();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(services.vault.profiles(CloudPlatform.webdav), isEmpty);
      await tester.runAsync(() async {
        unawaited(
          openLogin(context, services, CloudPlatform.webdav, addAccount: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('webdav-password')));
      await tester.enterText(
        find.byKey(const Key('webdav-password')),
        'session-password',
      );
      await tester.ensureVisible(find.text('连接并保存'));
      await screenshot(tester, 'phone-webdav-login');
      await tester.tap(find.text('连接并保存'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(WebDavLoginPage), findsNothing);
      final credential = services.vault.credential(CloudPlatform.webdav)!;
      expect(credential.field('rememberPassword'), 'false');
      expect(
        jsonEncode(services.store.data),
        isNot(contains('session-password')),
      );
      expect(connector.password(credential), 'session-password');
      expect(tester.takeException(), isNull);
    },
  );

  for (final fixture in [
    (size: const Size(320, 720), scale: 1.6, name: 'phone-large'),
    (size: const Size(844, 390), scale: 1.4, name: 'landscape-large'),
  ]) {
    testWidgets(
      'cloud restore ${fixture.name} shows failure, retry and versions; cancel preserves data',
      (tester) async {
        final services = await render(
          tester,
          size: fixture.size,
          scale: fixture.scale,
        );
        final original = services.cloud.connector(CloudPlatform.webdav);
        final client = BackupUiClient()..fail = true;
        final connector = BackupUiConnector(client: client);
        services.cloud.connectors[CloudPlatform.webdav] = connector;
        addTearDown(() async {
          services.cloud.connectors[CloudPlatform.webdav] = original;
          await tester.runAsync(connector.close);
        });
        await tester.runAsync(
          () => services.vault.putCredential(
            CloudPlatform.webdav,
            WebDavLocation.credential(
              url: 'https://fixture.example/dav/',
              username: 'user',
              password: 'test-secret',
              rememberPassword: true,
            ),
          ),
        );
        await tester.tap(find.text('恢复').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('网盘').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('backup-primary')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('user'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择“全部文件”'));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('backup-primary')));
        await tester.pumpAndSettle();
        expect(find.text('测试连接中断'), findsOneWidget);
        await tester.ensureVisible(find.text('重试'));
        await tester.pumpAndSettle();
        await screenshot(tester, '${fixture.name}-versions-error');
        expect(find.text('重试').hitTestable(), findsOneWidget);
        client.fail = false;
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(find.text('此目录没有已完成的备份'), findsOneWidget);
        const name = 'asterlink-backup-1795482000000-fixture.json';
        client.files = const [CloudFile(id: '/$name', name: name, size: 4096)];
        await tester.ensureVisible(find.text('显示旧版或未确认文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('显示旧版或未确认文件'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.textContaining(name));
        await tester.pumpAndSettle();
        expect(find.textContaining(name).hitTestable(), findsOneWidget);
        await screenshot(tester, '${fixture.name}-versions-list');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(services.store.data['backupUndo'], isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final fixture in [
    (size: const Size(320, 720), scale: 1.6, name: 'phone-large'),
    (size: const Size(844, 390), scale: 1.4, name: 'landscape-large'),
  ]) {
    testWidgets(
      'restore preview ${fixture.name} requires selected categories and confirmation',
      (tester) async {
        final source = StateStore.memory({
          'settings': {'destination': 'D:/old', 'threads': 19},
        });
        final bytes = (await tester.runAsync(
          () => ClassifiedBackupRepository(
            source,
          ).create(categories: {BackupCategory.settings}),
        ))!;
        final services = await render(
          tester,
          size: fixture.size,
          scale: fixture.scale,
          data: {
            'settings': {'destination': 'D:/current', 'threads': 8},
          },
        );
        final picker = BackupUiPicker()
          ..file = XFile.fromData(bytes, name: 'backup.json');
        final previous = FileSelectorPlatform.instance;
        FileSelectorPlatform.instance = picker;
        addTearDown(() => FileSelectorPlatform.instance = previous);
        await tester.tap(find.text('恢复').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('backup-primary')));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('预览与分类恢复'), findsOneWidget);
        expect(services.store.data.obj('settings').integer('threads'), 8);
        await screenshot(tester, '${fixture.name}-restore-preview');
        await tester.ensureVisible(
          find.byKey(const Key('restore-category-settings')),
        );
        await tester.tap(find.byKey(const Key('restore-category-settings')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, '恢复所选内容（0）'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const Key('restore-category-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('恢复所选内容（1）'));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        expect(services.store.data.obj('settings').integer('threads'), 19);
        expect(
          services.store.data.obj('settings').str('destination'),
          'D:/current',
        );
        expect(services.store.data['backupUndo'], isA<Map>());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final fixture in [
    (size: const Size(320, 720), scale: 1.6, name: 'phone-large'),
    (size: const Size(844, 390), scale: 1.4, name: 'landscape-large'),
  ]) {
    testWidgets(
      'restore account picker ${fixture.name} shows provider icons and binds favorites',
      (tester) async {
        final source = StateStore.memory();
        final sourceVault = Vault(source);
        await sourceVault.putCredential(
          CloudPlatform.quark,
          Credential('原来的夸克账号', {'primary': 'old-login'}),
        );
        final owner = sourceVault.activeAccountId(CloudPlatform.quark)!;
        await source.put('cloudFavorites', [
          CloudFavorite(
            id: 'fixture-favorite',
            session: BrowseSession(
              platform: CloudPlatform.quark,
              mode: BrowseMode.personal,
              title: '原来的夸克账号',
              rootId: '0',
              metadata: {'accountId': owner},
            ),
            file: const CloudFile(
              id: 'folder',
              name: '备份收藏',
              isDirectory: true,
            ),
            directoryId: '0',
            trail: [('0', '全部文件')],
            createdAt: 12,
          ).toJson(),
        ]);
        final bytes = (await tester.runAsync(
          () => ClassifiedBackupRepository(
            source,
          ).create(categories: {BackupCategory.favorites}),
        ))!;
        final services = await render(
          tester,
          size: fixture.size,
          scale: fixture.scale,
        );
        await tester.runAsync(
          () => services.vault.putCredential(
            CloudPlatform.quark,
            Credential('当前账号', {'primary': 'current-login'}),
          ),
        );
        final target = services.vault.activeAccountId(CloudPlatform.quark)!;
        const accountName = '家庭夸克账号与长期备份资料';
        await tester.runAsync(
          () => services.vault.renameAccount(
            CloudPlatform.quark,
            target,
            accountName,
          ),
        );
        final picker = BackupUiPicker()
          ..file = XFile.fromData(bytes, name: 'backup.json');
        final previous = FileSelectorPlatform.instance;
        FileSelectorPlatform.instance = picker;
        addTearDown(() => FileSelectorPlatform.instance = previous);
        await tester.tap(find.text('恢复').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('backup-primary')));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        final dropdown = find.byType(DropdownButtonFormField<String>);
        await tester.ensureVisible(dropdown);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        final accountItem = find.text(accountName).hitTestable();
        expect(accountItem, findsOneWidget);
        final row = find.ancestor(of: accountItem, matching: find.byType(Row));
        expect(
          tester
              .widget<PlatformMark>(
                find.descendant(of: row, matching: find.byType(PlatformMark)),
              )
              .platform,
          CloudPlatform.quark,
        );
        await screenshot(tester, '${fixture.name}-restore-account-picker');
        await tester.tap(accountItem);
        await tester.pumpAndSettle();
        expect(services.store.data.list('cloudFavorites'), isEmpty);
        await tester.tap(find.text('恢复所选内容（1）'));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        final restored = CloudFavorite.fromJson(
          services.store.data.list('cloudFavorites').single,
        );
        expect(restored.session.accountId, target);
        expect(services.store.data.list('backupPending'), isEmpty);
        expect(
          services.vault.credentialFor(CloudPlatform.quark, target)!.primary,
          'current-login',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'long unfinished targets and pending account data fit narrow layout',
    (tester) async {
      await render(
        tester,
        size: const Size(320, 720),
        scale: 1.6,
        dark: true,
        data: {
          'backupTransfers': [
            {
              'id': 'fixture',
              'name':
                  'asterlink-backup-1795482000000-12345678-1234-1234-1234-123456789012.json',
              'size': 1024,
              'createdAt': 1795482000000,
              'target': {
                'kind': 'webdav',
                'url':
                    'https://fixture.example/dav/very-long-directory-name/another-directory/',
              },
            },
          ],
          'backupPending': [
            {
              'account': {
                'platform': 'WebDAV',
                'id': 'fixture',
                'name': '家庭文件存储服务与备份账号',
              },
            },
          ],
        },
      );
      await tester.scrollUntilVisible(
        find.text('继续备份'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('backup-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 50,
      );
      expect(
        find.byKey(const Key('backup-primary')).hitTestable(),
        findsOneWidget,
      );
      await screenshot(tester, 'phone-large-pending');
      await tester.scrollUntilVisible(
        find.text('关联账号'),
        160,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('backup-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 50,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
