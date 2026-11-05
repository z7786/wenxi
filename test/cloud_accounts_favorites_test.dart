import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

class AccountFixtureConnector extends CloudConnector {
  AccountFixtureConnector(this.platform, this.vault);
  @override
  final CloudPlatform platform;
  final Vault vault;
  final reads = <String>[];
  Completer<void>? barrier;
  bool missing = false;
  String shareRoot = 'root';
  final shareReads = <ParsedLink>[];
  static const movie = CloudFile(
    id: 'movie',
    name: '假期.mp4',
    parentId: 'folder',
    size: 120,
  );
  static const folder = CloudFile(
    id: 'folder',
    name: '假期',
    parentId: 'root',
    isDirectory: true,
    token: '/假期',
  );
  @override
  Future<CloudAccount> account(Credential c) async => CloudAccount(c.label);
  @override
  Future<BrowseSession> openPersonal(Credential c) async => BrowseSession(
    platform: platform,
    mode: BrowseMode.personal,
    title: '网盘',
    rootId: 'root',
  );
  @override
  Future<BrowseSession> openShare(ParsedLink link, Credential? c) async {
    shareReads.add(link);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '分享',
      rootId: shareRoot,
      metadata: {'token': 'new-temporary-token'},
    );
  }

  @override
  Future<List<CloudSpace>> familySpaces(Credential c) async => [
    const CloudSpace('family', '家庭相册'),
  ];
  @override
  Future<BrowseSession> openFamily(CloudSpace space, Credential c) async =>
      BrowseSession(
        platform: platform,
        mode: BrowseMode.personal,
        title: '家庭云',
        rootId: 'family-root',
        metadata: {'familyId': space.id, 'familyName': space.name},
      );
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    expect(vault.credential(platform)?.primary, c?.primary);
    reads.add('${c?.label}:$parentId');
    if (missing) return [];
    return parentId == s.rootId ? [folder] : [movie];
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    await barrier?.future;
    expect(vault.credential(platform)?.primary, c?.primary);
    return DownloadSpec(
      url: 'https://fixture.invalid/${c?.label}/${f.id}',
      fileName: f.name,
      expectedSize: f.size,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> addFixtureAccount(
  Vault vault,
  CloudPlatform p,
  String name,
  int revision,
) async {
  final id = await vault.createAccount(p);
  await vault.withAccount(
    p,
    id,
    () => vault.putCredential(
      p,
      Credential(name, {
        'primary': 'fixture-$name',
        'secondary': 'fixture-password-$name',
      }, updatedAt: revision),
    ),
  );
  return id;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '123 and Xunlei device identities remain separate across accounts',
    () async {
      final store = StateStore.memory(), vault = Vault(store);
      final pan = Pan123Connector(FakeHttp(), vault),
          devices = XunleiDevices(vault);
      for (final p in [CloudPlatform.pan123, CloudPlatform.xunlei]) {
        final first = await addFixtureAccount(vault, p, 'A', 10),
            second = await addFixtureAccount(vault, p, 'B', 20);
        Future<String> identity() async => p == CloudPlatform.pan123
            ? await pan.loginUuid()
            : (await devices.get()).id;
        final a = await vault.withAccount(p, first, identity);
        final b = await vault.withAccount(p, second, identity);
        expect(a, isNot(b));
        expect(await vault.withAccount(p, first, identity), a);
      }
    },
  );

  test(
    'Malformed multi-account backup fails before modifying any local account',
    () async {
      final store = StateStore.memory(), vault = Vault(store);
      final first = await addFixtureAccount(
        vault,
        CloudPlatform.tianyi,
        'A',
        10,
      );
      await vault.activate(CloudPlatform.tianyi, first);
      final original = jsonEncode(store.data);
      final payload = {
        'schema': 1,
        'package': 'com.asterlink.app',
        'cloudAccounts': [false],
        'activeCloudAccounts': <String, String>{},
      };
      final encrypted = encryptBackup((payload, 'fixture-password'));
      await expectLater(
        BackupRepository(store).restore(encrypted, 'fixture-password'),
        throwsA(isA<AppException>()),
      );
      expect(jsonEncode(store.data), original);
    },
  );
  test(
    'Legacy migration preserves revisions, per-account secrets and global engine secret',
    () async {
      final old = Credential('旧账号', {
        'primary': 'fixture-old',
        'secondary': 'password',
      }, updatedAt: 31);
      final store = StateStore.memory({
        'credentials': {'123Pan': old.toJson()},
        'secrets': {
          'pan123.access_token': 'fixture-token',
          'gopeed.token': 'fixture-engine',
        },
      });
      // Use the canonical key so this test follows the installed format.
      await store.put('credentials', {CloudPlatform.pan123.key: old.toJson()});
      final vault = Vault(store),
          first = vault.activeAccountId(CloudPlatform.pan123)!;
      await vault.initializeAccounts();
      await vault.initializeAccounts();
      expect(vault.profiles(CloudPlatform.pan123), hasLength(1));
      expect(vault.credential(CloudPlatform.pan123)!.sameAs(old), isTrue);
      final second = await addFixtureAccount(
        vault,
        CloudPlatform.pan123,
        'B',
        40,
      );
      await vault.withAccount(
        CloudPlatform.pan123,
        second,
        () => vault.putSecret('pan123.access_token', 'fixture-B-token'),
      );
      await vault.activate(CloudPlatform.pan123, second);
      expect(vault.secret('pan123.access_token'), 'fixture-B-token');
      expect(vault.secret('gopeed.token'), 'fixture-engine');
      await vault.activate(CloudPlatform.pan123, first);
      expect(vault.secret('pan123.access_token'), 'fixture-token');
      expect(vault.credential(CloudPlatform.pan123)!.sameAs(old), isTrue);
    },
  );

  for (final platform in CloudPlatform.values.where((p) => p.requiresAccount)) {
    test(
      '${platform.key} downloads retain their account through switching and legacy origin recovery',
      () async {
        final store = StateStore.memory(),
            vault = Vault(store),
            http = FakeHttp();
        final repo = CloudRepository(http, vault, CleanupOutbox(store, http));
        final provider = AccountFixtureConnector(platform, vault);
        repo.connectors[platform] = provider;
        final first = await addFixtureAccount(vault, platform, 'A', 10);
        await vault.activate(platform, first);
        final session = await repo.personal(platform);
        final source = await repo.preparePlayback(
          session,
          AccountFixtureConnector.movie,
        );
        final second = await addFixtureAccount(vault, platform, 'B', 20);
        provider.barrier = Completer<void>();
        final pending = repo.prepare(session, AccountFixtureConnector.movie);
        await vault.activate(platform, second);
        provider.barrier!.complete();
        expect((await pending).url, contains('/A/'));
        expect((await repo.refresh(source)).url, contains('/A/'));
        final legacy = DownloadOrigin(
          BrowseSession.fromJson({
            ...session.toJson(),
            'metadata': <String, String>{},
          }),
          AccountFixtureConnector.movie,
          10,
        );
        expect((await repo.restoreOrigin(legacy)).session.accountId, first);
        expect(vault.activeAccountId(platform), second);
        await vault.removeAccount(platform, first);
        final count = provider.reads.length;
        await expectLater(repo.refresh(source), throwsA(isA<AppException>()));
        expect(provider.reads.length, count);
        expect(vault.credential(platform)!.label, 'B');
      },
    );
  }

  test(
    'Background credential renewal commits to its owner and notifications see active account',
    () async {
      final store = StateStore.memory(),
          vault = Vault(store),
          p = CloudPlatform.pan123;
      final first = await addFixtureAccount(vault, p, 'A', 10),
          second = await addFixtureAccount(vault, p, 'B', 20);
      await vault.activate(p, second);
      final observed = <String?>[];
      store.addListener(() => observed.add(vault.credential(p)?.label));
      final old = vault.credentialFor(p, first)!;
      final renewed = old.withFields({
        'accessToken': 'fixture-renewed-A',
      }, preserveRevision: true);
      expect(
        await vault.withAccount(
          p,
          first,
          () => vault.replaceCredential(p, old, renewed),
        ),
        isTrue,
      );
      expect(observed, everyElement('B'));
      expect(vault.credential(p)!.field('accessToken'), isEmpty);
      expect(
        vault.credentialFor(p, first)!.field('accessToken'),
        'fixture-renewed-A',
      );
      await vault.removeAccount(p, first);
      expect(
        await vault.withAccount(
          p,
          first,
          () => vault.replaceCredential(p, renewed, old),
        ),
        isFalse,
      );
    },
  );

  test(
    'Cancelled new login neither selects nor overwrites an existing account',
    () async {
      final store = StateStore.memory(),
          vault = Vault(store),
          p = CloudPlatform.quark;
      final first = await addFixtureAccount(vault, p, 'A', 10),
          second = await vault.createAccount(p);
      await vault.activate(p, first);
      final wait = Completer<LoginResult>();
      final login = AccountLoginService(
        vault,
        (_, _) async => const CloudAccount('unused'),
      );
      final pending = login.submit(p, (_) => wait.future, accountId: second);
      final failed = expectLater(pending, throwsA(isA<AppException>()));
      login.invalidate(p);
      await vault.removeAccount(p, second);
      wait.complete(
        LoginResult(
          Credential('B', {'primary': 'fixture-B'}),
          const CloudAccount('B'),
        ),
      );
      await failed;
      expect(vault.activeAccountId(p), first);
      expect(vault.profiles(p), hasLength(1));
    },
  );

  test(
    'Favorites isolate owners and spaces, reopen folders and locate files using fresh sessions',
    () async {
      final store = StateStore.memory(),
          vault = Vault(store),
          p = CloudPlatform.tianyi,
          http = FakeHttp();
      final repo = CloudRepository(http, vault, CleanupOutbox(store, http));
      final provider = AccountFixtureConnector(p, vault);
      repo.connectors[p] = provider;
      final favorites = CloudFavorites(store, repo);
      final first = await addFixtureAccount(vault, p, 'A', 10),
          second = await addFixtureAccount(vault, p, 'B', 20);
      await vault.activate(p, first);
      final personal = await repo.personal(p),
          family = await repo.family(p, 'family');
      await favorites.toggle(personal, AccountFixtureConnector.folder, [
        ('root', '全部文件'),
      ]);
      await favorites.toggle(personal, AccountFixtureConnector.movie, [
        ('root', '全部文件'),
        ('folder', '假期'),
      ]);
      await favorites.toggle(family, AccountFixtureConnector.movie, [
        ('family-root', '全部文件'),
        ('folder', '假期'),
      ]);
      await vault.activate(p, second);
      final other = await repo.personal(p);
      expect(
        favorites.contains(other, AccountFixtureConnector.folder),
        isFalse,
      );
      await favorites.toggle(other, AccountFixtureConnector.folder, [
        ('root', '全部文件'),
      ]);
      expect(favorites.all, hasLength(4));
      final firstFolder = favorites.all.firstWhere(
        (f) => f.file.isDirectory && f.session.accountId == first,
      );
      await favorites.rename(firstFolder.id, '  常用照片  ');
      final renamedFolder = favorites.all.firstWhere(
        (f) => f.id == firstFolder.id,
      );
      expect(renamedFolder.name, '常用照片');
      expect(renamedFolder.file.name, firstFolder.file.name);
      expect(renamedFolder.createdAt, firstFolder.createdAt);
      expect(
        favorites.contains(personal, AccountFixtureConnector.folder),
        isTrue,
      );
      final opened = await favorites.open(renamedFolder);
      expect(opened.trail.last.$1, 'folder');
      expect(opened.files.single.id, 'movie');
      expect(opened.session.accountId, first);
      final familyFile = favorites.all.firstWhere((f) => f.session.isFamily);
      await favorites.rename(familyFile.id, '旅行影片');
      final renamedFile = favorites.all.firstWhere(
        (f) => f.id == familyFile.id,
      );
      expect((await favorites.open(renamedFile)).highlight, 'movie');
      expect(renamedFile.file.name, '假期.mp4');
      await favorites.rename(familyFile.id, '   ');
      expect(
        favorites.all.firstWhere((f) => f.id == familyFile.id).name,
        '假期.mp4',
      );
      expect((await favorites.open(familyFile)).session.familyId, 'family');
      expect((await favorites.open(familyFile)).highlight, 'movie');
      expect(vault.activeAccountId(p), second);
      provider.missing = true;
      await expectLater(
        favorites.open(familyFile),
        throwsA(isA<AppException>()),
      );
      await vault.removeAccount(p, first);
      expect(favorites.all, hasLength(1));
      expect(favorites.all.single.session.accountId, second);
      await expectLater(
        favorites.rename(firstFolder.id, '失效收藏'),
        throwsA(isA<AppException>()),
      );
      expect(favorites.all, hasLength(1));
    },
  );

  test(
    'Share favorites retain codes, refresh roots and survive backup',
    () async {
      final store = StateStore.memory(),
          vault = Vault(store),
          http = FakeHttp();
      const p = CloudPlatform.tianyi;
      final repo = CloudRepository(http, vault, CleanupOutbox(store, http));
      final provider = AccountFixtureConnector(p, vault);
      repo.connectors[p] = provider;
      final favorites = CloudFavorites(store, repo);
      final owner = await addFixtureAccount(vault, p, 'A', 10);
      await vault.activate(p, owner);
      final link = ParsedLink(
        source: 'fixture share',
        url: 'https://cloud.189.cn/t/fixture',
        kind: LinkKind.cloudShare,
        platform: p,
        shareId: 'fixture',
        passcode: '1234',
      );
      final session = await repo.share(link);
      expect(await favorites.toggleShare(session), isTrue);
      await favorites.rename(favorites.all.single.id, '课程资料');
      final saved = favorites.all.single;
      expect(saved.name, '课程资料');
      expect(saved.isShareLink, isTrue);
      expect(saved.session.sourceLink!.passcode, '1234');
      expect(saved.session.meta('token'), isEmpty);
      // A real file with the same synthetic ID must remain a distinct favorite.
      await favorites.toggle(
        session,
        const CloudFile(id: '@share-link', name: 'folder', isDirectory: true),
        [('root', '全部文件')],
      );
      expect(favorites.all, hasLength(2));
      final bytes = await BackupRepository(store).create('fixture-password');
      final restored = StateStore.memory();
      await BackupRepository(restored).restore(bytes, 'fixture-password');
      final restoredFavorite = restored.data
          .list('cloudFavorites')
          .map(CloudFavorite.fromJson)
          .singleWhere((f) => f.isShareLink);
      expect(restoredFavorite.session.sourceLink!.passcode, '1234');
      expect(restoredFavorite.name, '课程资料');
      expect(restoredFavorite.file.name, session.title);
      provider.shareRoot = 'fresh-root';
      final second = await addFixtureAccount(vault, p, 'B', 20);
      await vault.activate(p, second);
      final reopened = await favorites.open(restoredFavorite);
      expect(reopened.trail, [('fresh-root', '全部文件')]);
      expect(reopened.session.accountId, owner);
      expect(reopened.highlight, isNull);
      expect(provider.shareReads.last.passcode, '1234');
      expect(provider.reads.last, 'A:fresh-root');
      expect(vault.activeAccountId(p), second);
      expect(favorites.containsShare(reopened.session), isTrue);
      expect(await favorites.toggleShare(reopened.session), isFalse);
      expect(favorites.all.single.isShareLink, isFalse);
    },
  );

  test(
    'Plain backup restores every account, selected owner, secrets and favorites',
    () async {
      final store = StateStore.memory(),
          vault = Vault(store),
          p = CloudPlatform.pan123,
          http = FakeHttp();
      final repo = CloudRepository(http, vault, CleanupOutbox(store, http));
      repo.connectors[p] = AccountFixtureConnector(p, vault);
      final first = await addFixtureAccount(vault, p, 'A', 10),
          second = await addFixtureAccount(vault, p, 'B', 20);
      await vault.withAccount(
        p,
        first,
        () => vault.putSecret('pan123.login_uuid', 'fixture-device-A'),
      );
      await vault.withAccount(
        p,
        second,
        () => vault.putSecret('pan123.login_uuid', 'fixture-device-B'),
      );
      await vault.activate(p, first);
      await CloudFavorites(store, repo).toggle(
        await repo.personal(p),
        AccountFixtureConnector.folder,
        [('root', '全部文件')],
      );
      await vault.activate(p, second);
      final bytes = await BackupRepository(store).create('fixture-password');
      expect(isPlainBackup(bytes), isTrue);
      expect(utf8.decode(bytes), contains('fixture-device-A'));
      final restored = StateStore.memory(), restoredVault = Vault(restored);
      expect(
        await BackupRepository(restored).restore(bytes, 'fixture-password'),
        2,
      );
      expect(restoredVault.activeAccountId(p), second);
      expect(restoredVault.profiles(p), hasLength(2));
      expect(restoredVault.secret('pan123.login_uuid'), 'fixture-device-B');
      expect(
        restoredVault.withAccount(
          p,
          first,
          () => restoredVault.secret('pan123.login_uuid'),
        ),
        'fixture-device-A',
      );
      expect(
        restored.data.list('cloudFavorites').single.str('accountId'),
        first,
      );
      expect(
        restoredVault.credentialFor(p, first)!.secondary,
        'fixture-password-A',
      );
      final before = jsonEncode(restored.data);
      final corrupt = asJson(jsonDecode(utf8.decode(bytes)));
      corrupt['data'] = {
        ...corrupt.obj('data'),
        'settings': {'theme': 'Dark'},
      };
      await expectLater(
        BackupRepository(
          restored,
        ).restore(Uint8List.fromList(utf8.encode(jsonEncode(corrupt))), ''),
        throwsA(isA<AppException>()),
      );
      expect(jsonEncode(restored.data), before);
    },
  );
}
