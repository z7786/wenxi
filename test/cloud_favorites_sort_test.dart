import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'cloud_accounts_favorites_test.dart'
    show AccountFixtureConnector, addFixtureAccount;
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StateStore store;
  late CloudRepository cloud;
  late CloudFavorites favorites;
  late AccountFixtureConnector provider;
  late BrowseSession session;

  setUp(() async {
    store = StateStore.memory();
    final vault = Vault(store), http = FakeHttp();
    cloud = CloudRepository(http, vault, CleanupOutbox(store, http));
    provider = AccountFixtureConnector(CloudPlatform.tianyi, vault);
    cloud.connectors[CloudPlatform.tianyi] = provider;
    final owner = await addFixtureAccount(vault, CloudPlatform.tianyi, 'A', 10);
    await vault.activate(CloudPlatform.tianyi, owner);
    session = await cloud.personal(CloudPlatform.tianyi);
    favorites = CloudFavorites(store, cloud);
    await store.put('cloudFavorites', [
      for (var i = 0; i < 5; i++)
        CloudFavorite(
            id: 'f$i',
            session: session,
            file: CloudFile(
              id: 'folder-$i',
              name: ['Bravo', 'alpha', 'Charlie', 'Delta', 'Echo'][i],
              isDirectory: true,
            ),
            directoryId: 'folder-$i',
            trail: [('root', '全部文件')],
            createdAt: 500 - i,
          ).toJson()
          ..remove('pinned')
          ..remove('lastOpenedAt'),
    ]);
  });

  List<String> ids() => favorites.all.map((favorite) => favorite.id).toList();

  test(
    'Legacy order becomes persistent manual order and survives sort switches',
    () async {
      expect(favorites.sort, CloudFavoriteSort.manual);
      expect(ids(), ['f0', 'f1', 'f2', 'f3', 'f4']);
      expect(
        favorites.all.every(
          (favorite) => !favorite.pinned && favorite.lastOpenedAt == 0,
        ),
        isTrue,
      );
      await favorites.reorder(['f2', 'f0', 'f1', 'f4', 'f3']);
      await favorites.setSort(CloudFavoriteSort.name);
      expect(ids(), ['f1', 'f0', 'f2', 'f3', 'f4']);
      await favorites.setSort(CloudFavoriteSort.newest);
      expect(ids(), ['f0', 'f1', 'f2', 'f3', 'f4']);
      await favorites.setSort(CloudFavoriteSort.manual);
      expect(ids(), ['f2', 'f0', 'f1', 'f4', 'f3']);
      final reopened = CloudFavorites(StateStore.memory(store.data), cloud);
      expect(reopened.sort, CloudFavoriteSort.manual);
      expect(reopened.all.map((favorite) => favorite.id), ids());
    },
  );

  test(
    'Pinned favorites stay first and new favorites lead the regular group',
    () async {
      await favorites.setPinned('f3', true);
      await favorites.setPinned('f1', true);
      expect(ids(), ['f1', 'f3', 'f0', 'f2', 'f4']);
      await favorites.reorder(['f4', 'f3', 'f2', 'f1', 'f0']);
      expect(ids(), ['f3', 'f1', 'f4', 'f2', 'f0']);
      await favorites.toggle(
        session,
        const CloudFile(id: 'new', name: 'New', isDirectory: true),
        [('root', '全部文件')],
      );
      final added = favorites.all.singleWhere(
        (favorite) => favorite.file.id == 'new',
      );
      expect(ids(), ['f3', 'f1', added.id, 'f4', 'f2', 'f0']);
      for (final sort in CloudFavoriteSort.values) {
        await favorites.setSort(sort);
        expect(
          favorites.all.take(2).every((favorite) => favorite.pinned),
          isTrue,
        );
      }
      await favorites.setSort(CloudFavoriteSort.manual);
      await favorites.setPinned('f3', false);
      expect(ids(), ['f1', 'f3', added.id, 'f4', 'f2', 'f0']);
    },
  );

  test(
    'Favorite names use pinyin and natural numbers with pins first',
    () async {
      final names = ['资料10', '阿里10', '阿里2', '音乐', '重庆'];
      for (final (index, name) in names.indexed) {
        await favorites.rename('f$index', name);
      }
      await favorites.setSort(CloudFavoriteSort.name);
      expect(ids(), ['f2', 'f1', 'f4', 'f3', 'f0']);
      await favorites.setPinned('f0', true);
      expect(ids(), ['f0', 'f2', 'f1', 'f4', 'f3']);
      await favorites.rename('f1', '阿里1');
      expect(ids(), ['f0', 'f1', 'f2', 'f4', 'f3']);
      await favorites.setSort(CloudFavoriteSort.manual);
      expect(ids(), ['f0', 'f1', 'f2', 'f3', 'f4']);
    },
  );

  test(
    'Homophone favorites keep their manual order as a tie breaker',
    () async {
      await favorites.rename('f0', '同01');
      await favorites.rename('f1', '童1');
      await favorites.reorder(['f1', 'f0', 'f2', 'f3', 'f4']);
      await favorites.setSort(CloudFavoriteSort.name);
      expect(ids(), ['f2', 'f3', 'f4', 'f1', 'f0']);
      await favorites.setPinned('f0', true);
      expect(ids(), ['f0', 'f2', 'f3', 'f4', 'f1']);
    },
  );

  test(
    'Filtered and stale reorder requests preserve hidden and newly added favorites',
    () async {
      await favorites.reorder(['f4', 'f1']);
      expect(ids(), ['f0', 'f4', 'f2', 'f3', 'f1']);
      await favorites.remove('f2');
      await favorites.toggle(
        session,
        const CloudFile(id: 'new', name: 'New', isDirectory: true),
        [('root', '全部文件')],
      );
      final added = favorites.all.first.id;
      await favorites.reorder(['f1', 'f3', 'f2', 'f4', 'f0']);
      expect(ids(), [added, 'f1', 'f3', 'f4', 'f0']);
      await favorites.rename('f1', 'renamed');
      await favorites.setSort(CloudFavoriteSort.newest);
      await favorites.reorder(['f4', 'f0']);
      expect(favorites.sort, CloudFavoriteSort.manual);
      expect(ids(), [added, 'f4', 'f1', 'f3', 'f0']);
      final before = ids();
      expect(
        () => favorites.reorder(['f1', 'f1']),
        throwsA(isA<AppException>()),
      );
      expect(ids(), before);
      expect(
        favorites.all.singleWhere((favorite) => favorite.id == 'f1').name,
        'renamed',
      );
    },
  );

  test(
    'Only successful opens advance recent use and manual order stays available',
    () async {
      await favorites.setPinned('f3', true);
      await favorites.setSort(CloudFavoriteSort.recent);
      await favorites.open(
        favorites.all.singleWhere((favorite) => favorite.id == 'f2'),
      );
      expect(ids(), ['f3', 'f2', 'f0', 'f1', 'f4']);
      final lastOpened = favorites.all[1].lastOpenedAt;
      expect(lastOpened, greaterThan(0));
      await favorites.open(
        favorites.all.singleWhere((favorite) => favorite.id == 'f4'),
      );
      expect(ids(), ['f3', 'f4', 'f2', 'f0', 'f1']);
      expect(favorites.all[1].lastOpenedAt, greaterThan(lastOpened));
      provider.missing = true;
      await favorites.toggle(session, AccountFixtureConnector.movie, [
        ('root', '全部文件'),
        ('folder', '假期'),
      ]);
      final movie = favorites.all.singleWhere(
        (favorite) => favorite.file.id == 'movie',
      );
      await expectLater(favorites.open(movie), throwsA(isA<AppException>()));
      expect(
        favorites.all
            .singleWhere((favorite) => favorite.id == movie.id)
            .lastOpenedAt,
        0,
      );
      await favorites.setSort(CloudFavoriteSort.manual);
      expect(ids(), ['f3', movie.id, 'f0', 'f1', 'f2', 'f4']);
    },
  );

  test(
    'Encrypted backup preserves pinning, manual order, recent use and selected sort',
    () async {
      await favorites.reorder(['f4', 'f2', 'f0', 'f1', 'f3']);
      await favorites.setPinned('f1', true);
      await favorites.open(
        favorites.all.singleWhere((favorite) => favorite.id == 'f2'),
      );
      await favorites.setSort(CloudFavoriteSort.recent);
      final bytes = await BackupRepository(store).create('fixture-password');
      final restored = StateStore.memory();
      await BackupRepository(restored).restore(bytes, 'fixture-password');
      final imported = CloudFavorites(restored, cloud);
      expect(imported.sort, CloudFavoriteSort.recent);
      expect(imported.all.map((favorite) => favorite.id), ids());
      expect(imported.all.first.pinned, isTrue);
      expect(imported.all[1].lastOpenedAt, greaterThan(0));
      await imported.setSort(CloudFavoriteSort.manual);
      expect(imported.all.map((favorite) => favorite.id), [
        'f1',
        'f4',
        'f2',
        'f0',
        'f3',
      ]);
    },
  );
}
