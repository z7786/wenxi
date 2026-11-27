import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector/file_selector.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/backgrounds.dart';
import 'package:asterlink/data/classified_backup.dart';
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/background.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/data/resource_search.dart';
import 'resource_search_test.dart' show SearchApiFixture;
import 'background_support.dart';

Future<String> addAccount(
  StateStore store, {
  String label = 'A',
  String token = 'secret-A',
}) async {
  final vault = Vault(store),
      id = await Vault(store).createAccount(CloudPlatform.quark);
  await vault.withAccount(
    CloudPlatform.quark,
    id,
    () => vault.putCredential(
      CloudPlatform.quark,
      Credential(label, {'primary': token}),
    ),
  );
  await vault.activate(CloudPlatform.quark, id);
  return id;
}

Json favorite(String owner) => CloudFavorite(
  id: 'old',
  session: BrowseSession(
    platform: CloudPlatform.quark,
    mode: BrowseMode.personal,
    title: 'Files',
    rootId: '0',
    metadata: {'accountId': owner},
  ),
  file: const CloudFile(id: 'folder', name: 'Documents', isDirectory: true),
  directoryId: '0',
  trail: [('0', '全部文件')],
  createdAt: 12,
).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Full search history survives backup restore and another search',
    () async {
      final terms = [for (var index = 1; index <= 80; index++) '搜索资料 $index'];
      final source = StateStore.memory({'resourceSearchHistory': terms});
      final target = StateStore.memory({
        'resourceSearchHistory': ['本机记录'],
      });
      addTearDown(source.dispose);
      addTearDown(target.dispose);
      final bytes = await ClassifiedBackupRepository(
        source,
      ).create(categories: {BackupCategory.history});
      final backup = ClassifiedBackupRepository(target);
      final preview = await backup.preview(bytes, '');
      await backup.restore(preview, categories: {BackupCategory.history});
      final search = ResourceSearch(
        store: target,
        api: SearchApiFixture((_, _) => const Stream.empty()),
      );
      addTearDown(search.dispose);
      expect(search.allHistory, ['本机记录', ...terms]);
      await search.search('搜索资料 80');
      await target.flush();
      expect(search.allHistory, ['搜索资料 80', '本机记录', ...terms.take(79)]);
      await backup.undo();
      expect(search.allHistory, ['本机记录']);
    },
  );

  test(
    'classified favorites preserve folders through encrypted restore and undo',
    () async {
      final source = StateStore.memory(), target = StateStore.memory();
      final owner = await addAccount(source);
      await source.put('cloudFavoriteFolders', [
        {'id': 'series', 'name': '剧集'},
      ]);
      await source.put('cloudFavorites', [
        {...favorite(owner), 'folderId': 'series'},
      ]);
      final bytes = await ClassifiedBackupRepository(source).create(
        categories: {BackupCategory.accounts, BackupCategory.favorites},
        password: 'test-password',
      );
      final repo = ClassifiedBackupRepository(target),
          preview = await ClassifiedBackupRepository(
            target,
          ).preview(bytes, 'test-password');
      await repo.restore(preview, categories: preview.categories);
      expect(target.data.list('cloudFavoriteFolders').single.str('name'), '剧集');
      expect(
        target.data.list('cloudFavorites').single.str('folderId'),
        'series',
      );
      await repo.undo();
      expect(target.data.list('cloudFavoriteFolders'), isEmpty);
      expect(target.data.list('cloudFavorites'), isEmpty);
    },
  );

  test(
    'legacy IDs never overwrite another installation and repeated imports are idempotent',
    () async {
      final source = StateStore.memory(), target = StateStore.memory();
      await source.put('credentials', {
        CloudPlatform.quark.key: Credential('source', {
          'primary': 'source-token',
        }).toJson(),
      });
      await target.put('credentials', {
        CloudPlatform.quark.key: Credential('target', {
          'primary': 'target-token',
        }).toJson(),
      });
      final bytes = await ClassifiedBackupRepository(
        source,
      ).create(categories: {BackupCategory.accounts});
      final repo = ClassifiedBackupRepository(target),
          preview = await ClassifiedBackupRepository(target).preview(bytes, '');
      await repo.restore(preview, categories: preview.categories);
      await repo.restore(preview, categories: preview.categories);
      expect(Vault(target).profiles(CloudPlatform.quark), hasLength(2));
      expect(
        Vault(target).credential(CloudPlatform.quark)!.field('primary'),
        'target-token',
      );
      expect(
        Vault(target)
            .profiles(CloudPlatform.quark)
            .where((p) => p.id.startsWith('backup-')),
        hasLength(1),
      );
    },
  );

  test(
    'combined account and playback restore can roll back to usable account revision',
    () async {
      final target = StateStore.memory();
      final owner = await addAccount(target);
      final revision = Vault(
        target,
      ).credentialFor(CloudPlatform.quark, owner)!.updatedAt;
      final session = BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'Drive',
        rootId: '0',
        metadata: {'accountId': owner},
      );
      const file = CloudFile(id: 'video', name: 'a.mp4', size: 123);
      final key = cloudPlaybackKey(session, file, revision);
      await target.put('playbackHistory', {
        key: PlaybackBookmark(
          position: const Duration(seconds: 10),
          duration: const Duration(minutes: 20),
          updatedAt: 1,
          source: PlaybackSource.cloud(DownloadOrigin(session, file, revision)),
        ).toJson(),
      });
      final source = StateStore.memory(target.data);
      final sourceVault = Vault(source);
      await sourceVault.withAccount(
        CloudPlatform.quark,
        owner,
        () => sourceVault.putCredential(
          CloudPlatform.quark,
          Credential('changed', {'primary': 'changed'}),
        ),
      );
      final bytes = await ClassifiedBackupRepository(
        source,
      ).create(categories: {BackupCategory.accounts, BackupCategory.playback});
      final repo = ClassifiedBackupRepository(target),
          preview = await ClassifiedBackupRepository(target).preview(bytes, '');
      await repo.restore(
        preview,
        categories: preview.categories,
        replaceAccounts: true,
      );
      await repo.undo();
      final restoredRevision = Vault(
        target,
      ).credentialFor(CloudPlatform.quark, owner)!.updatedAt;
      final history = target.data.obj('playbackHistory');
      expect(
        history.keys.single,
        cloudPlaybackKey(session, file, restoredRevision),
      );
      expect(
        history.values.single['source']['origin']['accountRevision'],
        restoredRevision,
      );
      expect(
        Vault(
          target,
        ).credentialFor(CloudPlatform.quark, owner)!.field('primary'),
        'secret-A',
      );
    },
  );

  test(
    'background-only restore preserves settings and undo retains image bytes after cleanup',
    () async {
      final root = await Directory.systemTemp.createTemp('classified-images-');
      addTearDown(() => root.delete(recursive: true));
      final source = StateStore.memory(),
          target = StateStore.memory({
            'settings': {'theme': 'Light', 'destination': 'phone'},
          });
      BackgroundRepository images(StateStore state, String dir) =>
          BackgroundRepository(
            Directory('${root.path}/$dir'),
            current: () =>
                AppSettings.fromJson(state.data.obj('settings')).background,
          );
      final sourceImages = images(source, 'source'),
          targetImages = images(target, 'target');
      final a = sourceImages.beginDraft(), b = targetImages.beginDraft();
      final day = await sourceImages.importFile(
        XFile.fromData(await backgroundFixture(width: 32, height: 48)),
        a,
      );
      final night = await targetImages.importFile(
        XFile.fromData(
          await backgroundFixture(width: 32, height: 48, night: true),
        ),
        b,
      );
      await source.put('settings', {
        'theme': 'Dark',
        'background': BackgroundSettings(day: day).toJson(),
      });
      await target.put('settings', {
        ...target.data.obj('settings'),
        'background': BackgroundSettings(day: night).toJson(),
      });
      await sourceImages.endDraft(a);
      await targetImages.endDraft(b);
      final bytes = await ClassifiedBackupRepository(
        source,
        backgrounds: sourceImages,
      ).create(categories: {BackupCategory.appearance});
      final repo = ClassifiedBackupRepository(
            target,
            backgrounds: targetImages,
          ),
          preview = await ClassifiedBackupRepository(target).preview(bytes, '');
      expect(
        preview
            .content(BackupCategory.appearance)
            .containsKey('backgroundImages'),
        isFalse,
      );
      expect(
        BackgroundSettings.fromJson(
          preview.content(BackupCategory.appearance).obj('background'),
        ).hasImage,
        isFalse,
      );
      await repo.restore(preview, categories: preview.categories);
      expect(target.data.obj('settings').str('theme'), 'Light');
      expect(target.data.obj('settings').str('destination'), 'phone');
      expect(await targetImages.file(night.id).exists(), isFalse);
      await ClassifiedBackupRepository(
        target,
        backgrounds: targetImages,
      ).undo();
      expect(
        AppSettings.fromJson(target.data.obj('settings')).background.day!.id,
        night.id,
      );
      expect(await targetImages.file(night.id).exists(), isTrue);
      final malformed = BackupPreview({
        ...preview.payload,
        'categories': {
          'appearance': {
            ...preview.content(BackupCategory.appearance),
            'backgroundImages': {day.id: 'broken'},
          },
        },
      });
      final before = jsonEncode(target.data);
      await expectLater(
        repo.restore(malformed, categories: malformed.categories),
        throwsA(isA<AppException>()),
      );
      expect(jsonEncode(target.data), before);
      expect(await targetImages.file(night.id).exists(), isTrue);
    },
  );

  test(
    'password affects exports only and wrong password never mutates state',
    () async {
      final source = StateStore.memory();
      await addAccount(source);
      final repo = ClassifiedBackupRepository(source);
      final plain = await repo.create(categories: {BackupCategory.accounts});
      final encrypted = await repo.create(
        categories: {BackupCategory.accounts},
        password: 'backup-password',
      );
      expect(isPlainBackup(plain), isTrue);
      expect(utf8.decode(plain), contains('secret-A'));
      expect(utf8.decode(encrypted), isNot(contains('secret-A')));
      expect(
        source.data
            .obj('credentials')
            .obj(CloudPlatform.quark.key)
            .obj('fields')
            .str('primary'),
        'secret-A',
      );
      final target = StateStore.memory({'sentinel': 'keep'}),
          restore = ClassifiedBackupRepository(target);
      await expectLater(
        restore.preview(encrypted, 'incorrect'),
        throwsA(isA<AppException>()),
      );
      expect(target.data, {'sentinel': 'keep'});
      final preview = await restore.preview(encrypted, 'backup-password');
      await restore.restore(preview, categories: preview.categories);
      expect(Vault(target).profiles(CloudPlatform.quark), hasLength(1));
      expect(
        isPlainBackup(await BackupRepository(source).create('password')),
        isFalse,
      );
    },
  );

  test(
    'selected categories exclude credentials, caches, device paths and queues',
    () async {
      final store = StateStore.memory({
        'settings': {'destination': 'D:/Downloads', 'theme': 'Dark'},
        'uploads': [
          {'private': 'queue'},
        ],
        'resourceSearch': {'incognito': true, 'cache': 'cache-secret'},
        'playbackHistory': {
          'local': PlaybackBookmark(
            position: Duration.zero,
            duration: Duration.zero,
            updatedAt: 1,
            source: const PlaybackSource.local(path: 'D:/private/video.mp4'),
          ).toJson(),
        },
      });
      await addAccount(store);
      final bytes = await ClassifiedBackupRepository(store).create(
        categories: {
          BackupCategory.settings,
          BackupCategory.search,
          BackupCategory.playback,
        },
      );
      final text = utf8.decode(bytes);
      for (final excluded in [
        'secret-A',
        'D:/Downloads',
        'D:/private',
        'queue',
        'cache-secret',
      ]) {
        expect(text, isNot(contains(excluded)));
      }
      final preview = await ClassifiedBackupRepository(
        store,
      ).preview(bytes, '');
      expect(preview.categories, {
        BackupCategory.settings,
        BackupCategory.search,
        BackupCategory.playback,
      });
    },
  );

  test(
    'partial restore preserves device destination and other categories and can undo after restart',
    () async {
      final source = StateStore.memory({
        'settings': {'theme': 'Dark', 'destination': 'C:/elsewhere'},
        'history': [
          {'id': 'new'},
        ],
      });
      final bytes = await ClassifiedBackupRepository(
        source,
      ).create(categories: {BackupCategory.settings, BackupCategory.history});
      final root = await Directory.systemTemp.createTemp('classified-state-');
      addTearDown(() => root.delete(recursive: true));
      final target = await StateStore.open(root);
      await target.change((d) {
        d['settings'] = {'theme': 'Light', 'destination': '/phone/original'};
        d['history'] = [
          {'id': 'old'},
        ];
      });
      final restore = ClassifiedBackupRepository(target),
          preview = await ClassifiedBackupRepository(target).preview(bytes, '');
      await restore.restore(preview, categories: {BackupCategory.settings});
      expect(target.data.obj('settings').str('theme'), 'Dark');
      expect(target.data.obj('settings').str('destination'), '/phone/original');
      expect(target.data.list('history').single.str('id'), 'old');
      expect(
        jsonDecode(await target.file!.readAsString())['format'],
        'asterlink-state-v2',
      );
      final reopened = await StateStore.open(root),
          undo = ClassifiedBackupRepository(await StateStore.open(root));
      expect(ClassifiedBackupRepository(reopened).canUndo, isTrue);
      await undo.undo();
      expect(undo.store.data.obj('settings').str('theme'), 'Light');
      expect(
        undo.store.data.obj('settings').str('destination'),
        '/phone/original',
      );
      expect(undo.canUndo, isFalse);
    },
  );

  test(
    'favorites without credentials stay pending and later bind and deduplicate',
    () async {
      final source = StateStore.memory();
      final original = await addAccount(source);
      await source.put('cloudFavorites', [favorite(original)]);
      final bytes = await ClassifiedBackupRepository(
        source,
      ).create(categories: {BackupCategory.favorites});
      final target = StateStore.memory(),
          restore = ClassifiedBackupRepository(target);
      final preview = await restore.preview(bytes, '');
      await restore.restore(preview, categories: preview.categories);
      await restore.restore(preview, categories: preview.categories);
      expect(restore.pending, hasLength(1));
      expect(
        restore.pending.single
            .obj('categories')
            .obj('favorites')
            .list('cloudFavorites'),
        hasLength(1),
      );
      expect(target.data.list('cloudFavorites'), isEmpty);
      final reexport = await restore.create(
        categories: {BackupCategory.favorites},
      );
      expect(
        (await restore.preview(reexport, '')).count(BackupCategory.favorites),
        1,
      );
      final account = await addAccount(target, token: 'local-token');
      await restore.bindPending(restore.pending.single, account);
      expect(restore.pending, isEmpty);
      expect(
        target.data.list('cloudFavorites').single.str('accountId'),
        account,
      );
      await restore.restore(
        preview,
        categories: preview.categories,
        bindings: {'${CloudPlatform.quark.key}/$original': account},
      );
      expect(target.data.list('cloudFavorites'), hasLength(1));
    },
  );

  test(
    'account conflicts preserve local credentials unless replacement selected',
    () async {
      final source = StateStore.memory();
      final id = await addAccount(source);
      final bytes = await ClassifiedBackupRepository(
        source,
      ).create(categories: {BackupCategory.accounts});
      final target = StateStore.memory(source.data);
      final targetVault = Vault(target);
      await targetVault.withAccount(
        CloudPlatform.quark,
        id,
        () => targetVault.putCredential(
          CloudPlatform.quark,
          Credential('local', {'primary': 'local-token'}),
        ),
      );
      final restore = ClassifiedBackupRepository(target),
          preview = await ClassifiedBackupRepository(target).preview(bytes, '');
      final revision = Vault(
        target,
      ).credentialFor(CloudPlatform.quark, id)!.updatedAt;
      await restore.restore(preview, categories: preview.categories);
      expect(
        Vault(target).credentialFor(CloudPlatform.quark, id)!.field('primary'),
        'local-token',
      );
      await restore.restore(
        preview,
        categories: preview.categories,
        replaceAccounts: true,
      );
      expect(
        Vault(target).credentialFor(CloudPlatform.quark, id)!.field('primary'),
        'secret-A',
      );
      final replaced = Vault(
        target,
      ).credentialFor(CloudPlatform.quark, id)!.updatedAt;
      expect(replaced, greaterThan(revision));
      await restore.undo();
      expect(
        Vault(target).credentialFor(CloudPlatform.quark, id)!.field('primary'),
        'local-token',
      );
      expect(
        Vault(target).credentialFor(CloudPlatform.quark, id)!.updatedAt,
        greaterThan(replaced),
      );
    },
  );

  test(
    'playback merge uses modification time and remaps account revision',
    () async {
      final source = StateStore.memory();
      final id = await addAccount(source);
      final session = BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'Files',
        rootId: '0',
        metadata: {'accountId': id},
      );
      const file = CloudFile(id: 'video', name: 'test.mp4', size: 100);
      final revision = Vault(
        source,
      ).credentialFor(CloudPlatform.quark, id)!.updatedAt;
      final key = cloudPlaybackKey(session, file, revision);
      Json mark(int at, int position) => PlaybackBookmark(
        position: Duration(seconds: position),
        duration: const Duration(minutes: 30),
        updatedAt: at,
        source: PlaybackSource.cloud(DownloadOrigin(session, file, revision)),
      ).toJson();
      await source.put('playbackHistory', {key: mark(100, 30)});
      final bytes = await ClassifiedBackupRepository(
        source,
      ).create(categories: {BackupCategory.playback});
      final target = StateStore.memory(source.data);
      await target.put('playbackHistory', {key: mark(99, 700)});
      final repo = ClassifiedBackupRepository(target),
          preview = await ClassifiedBackupRepository(target).preview(bytes, '');
      await repo.restore(preview, categories: preview.categories);
      expect(
        target.data.obj('playbackHistory').obj(key).integer('position'),
        30000,
      );
      await target.put('playbackHistory', {key: mark(101, 15)});
      await repo.restore(preview, categories: preview.categories);
      expect(
        target.data.obj('playbackHistory').obj(key).integer('position'),
        15000,
      );
    },
  );

  test(
    'legacy backups remain selectable and new packages work through startup importer',
    () async {
      final source = StateStore.memory({
        'settings': {'theme': 'Dark'},
      });
      await addAccount(source);
      final bytes = await BackupRepository(source).create('');
      final target = StateStore.memory({
            'settings': {'destination': 'phone-path'},
          }),
          repo = ClassifiedBackupRepository(target);
      final preview = await repo.preview(bytes, '');
      expect(preview.legacy, isTrue);
      await repo.restore(preview, categories: {BackupCategory.settings});
      expect(target.data.obj('settings').str('destination'), 'phone-path');
      expect(Vault(target).profiles(CloudPlatform.quark), isEmpty);
      final classified = await ClassifiedBackupRepository(
        source,
      ).create(categories: {BackupCategory.accounts});
      expect(await BackupRepository(target).restore(classified, ''), 1);
    },
  );

  test(
    'malformed content and cancellation leave committed state and undo untouched',
    () async {
      final target = StateStore.memory({
            'settings': {'theme': 'Light'},
          }),
          repo = ClassifiedBackupRepository(target);
      final invalid = encodePlainBackup({
        'schema': 1,
        'package': 'com.asterlink.app',
        'classifiedVersion': 1,
        'categories': {
          'settings': {
            'settings': {'theme': 'Dark'},
          },
          'accounts': {
            'cloudAccounts': [
              {'id': '../bad', 'platform': 'quark'},
            ],
          },
        },
      });
      await expectLater(
        repo.preview(invalid, ''),
        throwsA(isA<AppException>()),
      );
      expect(target.data, {
        'settings': {'theme': 'Light'},
      });
      final bytes = await ClassifiedBackupRepository(
        StateStore.memory({
          'settings': {'theme': 'Dark'},
        }),
      ).create(categories: {BackupCategory.settings});
      final preview = await repo.preview(bytes, ''),
          scope = RequestScope()..cancel();
      await expectLater(
        scope.run(() => repo.restore(preview, categories: preview.categories)),
        throwsA(isA<AppException>()),
      );
      expect(target.data, {
        'settings': {'theme': 'Light'},
      });
    },
  );
}
