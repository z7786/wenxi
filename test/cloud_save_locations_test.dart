import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_save_locations.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';

Future<BrowseSession> _account(
  Vault vault,
  CloudPlatform platform,
  String name,
) async {
  final id = await vault.createAccount(platform);
  await vault.withAccount(
    platform,
    id,
    () => vault.putCredential(
      platform,
      Credential(name, {'primary': 'private-$name'}, updatedAt: 1),
    ),
  );
  return BrowseSession(
    platform: platform,
    mode: BrowseMode.personal,
    title: '文件',
    rootId: 'root',
    metadata: {'token': 'temporary-token', 'cookie': 'private-cookie'},
  ).withAccount(id);
}

BrowseSession _space(
  BrowseSession session, {
  String root = 'root',
  String drive = '',
  String family = '',
}) => BrowseSession(
  platform: session.platform,
  mode: session.mode,
  title: session.title,
  rootId: root,
  metadata: {
    'accountId': session.accountId!,
    if (drive.isNotEmpty) 'driveId': drive,
    if (family.isNotEmpty) 'familyId': family,
  },
);

const _trail = [('root', '全部文件'), ('work', '工作资料'), ('2026', '今年')];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Save location survives reopening state without storing credentials',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cloud-save-location-',
      );
      final store = await StateStore.open(directory);
      StateStore? reopened;
      try {
        final session = await _account(
          Vault(store),
          CloudPlatform.quark,
          'first',
        );
        await CloudSaveLocations(store).remember(session, _trail);
        reopened = await StateStore.open(directory);
        expect(CloudSaveLocations(reopened).read(session), _trail);
        final saved = reopened.data.obj('cloudSaveLocations').values.single;
        expect(
          asJson(saved).keys,
          unorderedEquals(['platform', 'accountId', 'trail']),
        );
        expect(jsonEncode(saved), isNot(contains('private-')));
        expect(jsonEncode(saved), isNot(contains('temporary-token')));
        expect(
          Vault(
            reopened,
          ).credentialFor(session.platform, session.accountId)?.primary,
          'private-first',
        );
      } finally {
        reopened?.dispose();
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Locations stay within their platform, owner and storage space',
    () async {
      final store = StateStore.memory();
      addTearDown(store.dispose);
      final vault = Vault(store), locations = CloudSaveLocations(store);
      final first = await _account(vault, CloudPlatform.aliyun, 'first');
      final second = await _account(vault, CloudPlatform.aliyun, 'second');
      final other = await _account(vault, CloudPlatform.quark, 'other');
      final resource = _space(first, drive: 'resource');
      final backup = _space(first, drive: 'backup');
      final family = _space(first, root: '', family: 'family');
      final otherFamily = _space(first, root: '', family: 'other-family');
      await locations.remember(first, _trail);
      await locations.remember(second, [('root', '全部文件'), ('photos', '相册')]);
      await locations.remember(resource, [('root', '全部文件'), ('movies', '电影')]);
      await locations.remember(family, [
        ('', '全部文件'),
        ('family-photos', '家庭相册'),
      ]);
      expect(locations.read(first), _trail);
      expect(locations.read(second)!.last.$1, 'photos');
      expect(locations.read(other), isNull);
      expect(locations.read(resource)!.last.$1, 'movies');
      expect(locations.read(backup), isNull);
      expect(locations.read(family)!.first.$1, '');
      expect(locations.read(otherFamily), isNull);
      expect(locations.read(_space(first, root: 'different-root')), isNull);

      final share = BrowseSession(
        platform: first.platform,
        mode: BrowseMode.share,
        title: '分享',
        rootId: first.rootId,
        metadata: first.metadata,
      );
      expect(locations.read(share), isNull);
      expect(locations.read(first.withAccount('')), isNull);
    },
  );

  test(
    'Queued writes use the latest path and cannot revive removed accounts',
    () async {
      final store = StateStore.memory();
      addTearDown(store.dispose);
      final vault = Vault(store), locations = CloudSaveLocations(store);
      final first = await _account(vault, CloudPlatform.quark, 'first');
      final second = await _account(vault, CloudPlatform.quark, 'second');
      final initial = locations.remember(first, _trail);
      final latestTrail = [('root', '全部文件'), ('photos', '相册')];
      final latest = locations.remember(first, latestTrail);
      expect(locations.read(first), latestTrail);
      await Future.wait([initial, latest]);
      await locations.remember(second, _trail);
      expect(CloudSaveLocations(store).read(first), latestTrail);
      final removal = vault.removeAccount(first.platform, first.accountId!);
      final lateWrite = locations.remember(first, _trail);
      await Future.wait([removal, lateWrite]);
      expect(locations.read(first), isNull);
      expect(locations.read(second), _trail);
      expect(
        store.data
            .obj('cloudSaveLocations')
            .values
            .any((raw) => asJson(raw).str('accountId') == first.accountId),
        isFalse,
      );
    },
  );

  test(
    'Malformed or incomplete saved paths safely use the default location',
    () async {
      final store = StateStore.memory();
      addTearDown(store.dispose);
      final locations = CloudSaveLocations(store);
      final session = await _account(
        Vault(store),
        CloudPlatform.quark,
        'first',
      );
      await locations.remember(session, _trail);
      final key = store.data.obj('cloudSaveLocations').keys.single;
      final valid = store.data.obj('cloudSaveLocations').obj(key);
      for (final raw in [
        null,
        'wrong-type',
        {...valid, 'accountId': 'another-owner'},
        {...valid, 'trail': []},
        {
          ...valid,
          'trail': [false],
        },
        {
          ...valid,
          'trail': [
            {'id': 'wrong-root', 'name': '全部文件'},
          ],
        },
        {
          ...valid,
          'trail': [
            {'id': 'root', 'name': '全部文件'},
            {'id': '', 'name': '无效目录'},
          ],
        },
        {
          ...valid,
          'trail': [
            {'id': 'root', 'name': '全部文件'},
            {'id': 'root', 'name': '重复目录'},
          ],
        },
      ]) {
        await store.put('cloudSaveLocations', {key: raw});
        expect(locations.read(session), isNull);
      }
      await locations.remember(session, _trail);
      expect(locations.read(session), _trail);
    },
  );
}
