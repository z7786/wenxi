import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/json.dart';
import '../core/natural_name.dart';
import '../domain/models.dart';
import '../diagnostics/app_log.dart';
import 'cloud_repository.dart';
import 'state_store.dart';

enum CloudFavoriteSort {
  manual('手动排序'),
  newest('最近收藏'),
  recent('最近使用'),
  name('名称排序');

  const CloudFavoriteSort(this.label);
  final String label;

  static CloudFavoriteSort fromName(String value) =>
      values.where((sort) => sort.name == value).firstOrNull ?? manual;
}

class CloudFavorite {
  const CloudFavorite({
    required this.id,
    required this.session,
    required this.file,
    required this.directoryId,
    required this.trail,
    required this.createdAt,
    this.isShareLink = false,
    this.customName = '',
    this.pinned = false,
    this.sortOrder,
    this.lastOpenedAt = 0,
  });
  final String id, directoryId;
  final BrowseSession session;
  final CloudFile file;
  final List<(String, String)> trail;
  final int createdAt, lastOpenedAt;
  final int? sortOrder;
  final bool isShareLink, pinned;
  final String customName;
  String get name => customName.ifEmpty(file.name);
  String get location => isShareLink
      ? '分享链接 / ${session.sourceLink?.url ?? ''}'
      : [
          session.isFamily
              ? session.meta('familyName').ifEmpty('家庭云')
              : session.mode == BrowseMode.share
              ? '分享文件'
              : session.meta('driveName').ifEmpty('个人网盘'),
          ...trail.skip(1).map((e) => e.$2),
        ].join(' / ');
  Json toJson() => {
    'id': id,
    'platform': session.platform.key,
    'accountId': session.accountId ?? '',
    'session': BrowseSession(
      platform: session.platform,
      mode: session.mode,
      title: session.title,
      rootId: session.rootId,
      metadata: {
        ...session.spaceMetadata,
        'accountId': session.accountId ?? '',
      },
      sourceLink: session.sourceLink,
    ).toJson(),
    'file': {...file.toJson(), 'token': ''},
    'directoryId': directoryId,
    'trail': [
      for (final e in trail) {'id': e.$1, 'name': e.$2},
    ],
    'createdAt': createdAt,
    'isShareLink': isShareLink,
    'customName': customName,
    'pinned': pinned,
    if (sortOrder != null) 'sortOrder': sortOrder,
    'lastOpenedAt': lastOpenedAt,
  };
  factory CloudFavorite.fromJson(Json j) => CloudFavorite(
    id: j.str('id'),
    session: BrowseSession.fromJson(j.obj('session')),
    file: CloudFile.fromJson(j.obj('file')),
    directoryId: j.str('directoryId'),
    trail: j.list('trail').map((e) => (e.str('id'), e.str('name'))).toList(),
    createdAt: j.integer('createdAt'),
    isShareLink: j.boolean('isShareLink'),
    customName: j.str('customName').trim(),
    pinned: j.boolean('pinned'),
    sortOrder: j['sortOrder'] != null && j.integer('sortOrder', -1) >= 0
        ? j.integer('sortOrder')
        : null,
    lastOpenedAt: j.integer('lastOpenedAt') > 0 ? j.integer('lastOpenedAt') : 0,
  );
}

class CloudFavorites {
  CloudFavorites(this.store, this.cloud);
  final StateStore store;
  final CloudRepository cloud;
  Object? _orderedSource, _idsSource;
  CloudFavoriteSort? _orderedSort;
  List<CloudFavorite> _orderedSnapshot = const [];
  Set<String> _ids = const {};
  CloudFavoriteSort get sort =>
      CloudFavoriteSort.fromName(store.data.str('cloudFavoriteSort'));

  List<CloudFavorite> get all {
    final source = store.data['cloudFavorites'], order = sort;
    if (!identical(source, _orderedSource) || order != _orderedSort) {
      _orderedSource = source;
      _orderedSort = order;
      _orderedSnapshot = List.unmodifiable(_ordered(store.data, order));
    }
    return _orderedSnapshot;
  }

  Set<String> get _favoriteIds {
    final source = store.data['cloudFavorites'];
    if (!identical(source, _idsSource)) {
      _idsSource = source;
      _ids = store.data
          .list('cloudFavorites')
          .map((favorite) => favorite.str('id'))
          .toSet();
    }
    return _ids;
  }

  static List<CloudFavorite> _ordered(Json data, CloudFavoriteSort sort) {
    final favorites = data
        .list('cloudFavorites')
        .map(CloudFavorite.fromJson)
        .toList();
    final positions = {
      for (final (index, favorite) in favorites.indexed) favorite.id: index,
    };
    final names = sort == CloudFavoriteSort.name
        ? {
            for (final favorite in favorites)
              favorite.id: NaturalName(favorite.name),
          }
        : <String, NaturalName>{};
    int manual(CloudFavorite a, CloudFavorite b) {
      final order = (a.sortOrder ?? 0x7fffffffffffffff).compareTo(
        b.sortOrder ?? 0x7fffffffffffffff,
      );
      if (order != 0) return order;
      final created = b.createdAt.compareTo(a.createdAt);
      return created != 0
          ? created
          : positions[a.id]!.compareTo(positions[b.id]!);
    }

    return favorites..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final compared = switch (sort) {
        CloudFavoriteSort.manual => manual(a, b),
        CloudFavoriteSort.newest => b.createdAt.compareTo(a.createdAt),
        CloudFavoriteSort.recent => b.lastOpenedAt.compareTo(a.lastOpenedAt),
        CloudFavoriteSort.name => names[a.id]!.compareTo(names[b.id]!),
      };
      return compared != 0 ? compared : manual(a, b);
    });
  }

  static void _saveOrder(Json draft, List<String> ids) {
    final positions = {for (final (index, id) in ids.indexed) id: index};
    draft['cloudFavorites'] = [
      for (final favorite in draft.list('cloudFavorites'))
        {...favorite, 'sortOrder': positions[favorite.str('id')]!},
    ];
  }

  Future<void> setSort(CloudFavoriteSort value) =>
      store.put('cloudFavoriteSort', value.name);

  /// Replace only the visible slots, keeping hidden accounts and search results
  /// in place. A drag preserves the current display as the new manual order.
  Future<void> reorder(List<String> visibleIds) {
    final requested = List<String>.of(visibleIds);
    require(requested.toSet().length == requested.length, '收藏排序不能包含重复项');
    return store.change((draft) {
      final current = _ordered(
        draft,
        CloudFavoriteSort.fromName(draft.str('cloudFavoriteSort')),
      );
      final byId = {for (final favorite in current) favorite.id: favorite};
      final requestedSet = requested.toSet();
      final pinned = requested.where((id) => byId[id]?.pinned == true).iterator;
      final regular = requested
          .where((id) => byId[id]?.pinned == false)
          .iterator;
      final ids = [
        for (final favorite in current)
          if (!requestedSet.contains(favorite.id))
            favorite.id
          else if ((favorite.pinned ? pinned : regular).moveNext())
            (favorite.pinned ? pinned : regular).current,
      ];
      _saveOrder(draft, ids);
      draft['cloudFavoriteSort'] = CloudFavoriteSort.manual.name;
    });
  }

  Future<void> setPinned(String id, bool pinned) => store.change((draft) {
    final favorites = draft.list('cloudFavorites');
    final index = favorites.indexWhere((favorite) => favorite.str('id') == id);
    require(index >= 0, '该收藏已移除，请刷新后重试');
    if (favorites[index].boolean('pinned') == pinned) return;
    final ordered = _ordered(
      draft,
      CloudFavoriteSort.manual,
    ).where((favorite) => favorite.id != id).toList();
    favorites[index] = {...favorites[index], 'pinned': pinned};
    draft['cloudFavorites'] = favorites;
    final ids = ordered.map((favorite) => favorite.id).toList();
    final regular = ordered.indexWhere((favorite) => !favorite.pinned);
    ids.insert(pinned ? 0 : (regular < 0 ? ids.length : regular), id);
    _saveOrder(draft, ids);
  });

  String key(
    BrowseSession session,
    CloudFile file, {
    bool isShareLink = false,
  }) {
    session = cloud.bindSession(session);
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              session.platform.key,
              if (isShareLink) 'share-link',
              session.accountId,
              session.mode.name,
              session.familyId,
              if (session.personalSpaceId.isNotEmpty) session.personalSpaceId,
              session.sourceLink?.shareId ?? session.sourceLink?.url ?? '',
              file.id,
              file.isDirectory,
            ]),
          ),
        )
        .toString();
  }

  bool contains(BrowseSession session, CloudFile file) =>
      _favoriteIds.contains(key(session, file));

  CloudFile _shareFile(BrowseSession session) => CloudFile(
    id: '@share-link',
    name: session.title.ifEmpty('${session.platform.shortName}分享链接'),
    isDirectory: true,
  );

  bool containsShare(BrowseSession session) => _favoriteIds.contains(
    key(session, _shareFile(session), isShareLink: true),
  );

  Future<bool> toggleShare(BrowseSession session) => toggle(
    session,
    _shareFile(session),
    [(session.rootId, '全部文件')],
    isShareLink: true,
  );

  Future<bool> toggle(
    BrowseSession session,
    CloudFile file,
    List<(String, String)> trail, {
    bool isShareLink = false,
  }) async {
    session = cloud.bindSession(session);
    require(trail.isNotEmpty && trail.first.$1 == session.rootId, '收藏目录信息不完整');
    if (isShareLink) {
      require(
        session.mode == BrowseMode.share && session.sourceLink != null,
        '请先解析分享链接再收藏',
      );
    }
    final id = key(session, file, isShareLink: isShareLink);
    return store.change((draft) {
      final favorites = draft.list('cloudFavorites');
      if (favorites.any((e) => e.str('id') == id)) {
        draft['cloudFavorites'] = favorites
            .where((e) => e.str('id') != id)
            .toList();
        return false;
      }
      require(favorites.length < 2000, '收藏已达 2000 项，请先移除不需要的收藏');
      final owner = session.accountId;
      if (owner?.isNotEmpty == true) {
        require(
          Vault.credentialIn(draft, session.platform, owner) != null,
          '该账号已移除',
        );
      }
      draft['cloudFavorites'] = [
        ...favorites,
        CloudFavorite(
          id: id,
          session: session,
          file: file,
          directoryId: isShareLink
              ? session.rootId
              : file.isDirectory
              ? cloud.directoryId(session, file)
              : trail.last.$1,
          trail: List.of(trail),
          createdAt: DateTime.now().millisecondsSinceEpoch,
          isShareLink: isShareLink,
        ).toJson(),
      ];
      final ordered = _ordered(
        draft,
        CloudFavoriteSort.manual,
      ).where((favorite) => favorite.id != id).toList();
      final ids = ordered.map((favorite) => favorite.id).toList();
      final regular = ordered.indexWhere((favorite) => !favorite.pinned);
      ids.insert(regular < 0 ? ids.length : regular, id);
      _saveOrder(draft, ids);
      return true;
    });
  }

  Future<void> remove(String id) => store.change((draft) {
    draft['cloudFavorites'] = draft
        .list('cloudFavorites')
        .where((e) => e.str('id') != id)
        .toList();
  });

  Future<void> rename(String id, String name) => store.change((draft) {
    final value = name.trim();
    require(value.runes.length <= 80, '收藏名称最多 80 个字符');
    require(!RegExp(r'[\x00-\x1f\x7f]').hasMatch(value), '收藏名称不能包含换行或控制字符');
    final favorites = draft.list('cloudFavorites');
    final index = favorites.indexWhere((favorite) => favorite.str('id') == id);
    require(index >= 0, '该收藏已移除，请刷新后重试');
    favorites[index] = {...favorites[index], 'customName': value};
    draft['cloudFavorites'] = favorites;
  });

  Future<
    ({
      BrowseSession session,
      List<(String, String)> trail,
      List<CloudFile> files,
      String? cursor,
      String? highlight,
    })
  >
  open(CloudFavorite favorite) => cloud.withSession(favorite.session, () async {
    final previous = favorite.session;
    cloud.ensureAvailable(previous.platform);
    if (previous.accountId?.isNotEmpty == true) {
      require(cloud.sessionCredential(previous) != null, '收藏所属账号已移除，请重新添加收藏');
    }
    final session = previous.mode == BrowseMode.share
        ? await cloud.share(
            previous.sourceLink ?? (throw const AppException('原分享信息缺失，请重新收藏')),
          )
        : await cloud.reopenSpace(previous);
    require(favorite.trail.isNotEmpty, '收藏目录信息缺失，请重新收藏');
    final trail = [
      (session.rootId, '全部文件'),
      if (!favorite.isShareLink) ...favorite.trail.skip(1),
    ];
    if (favorite.file.isDirectory && !favorite.isShareLink) {
      final id = favorite.directoryId == previous.rootId
          ? session.rootId
          : favorite.directoryId;
      if (trail.last.$1 != id) trail.add((id, favorite.file.name));
    }
    final page = await cloud.listPage(session, trail.last.$1);
    final files = {for (final file in page.files) file.id: file};
    var cursor = page.nextCursor;
    if (!favorite.file.isDirectory) {
      // Locate a saved file across batches, but leave the remaining pages for
      // the browser to load as the user scrolls.
      final seen = <String>{};
      while (files[favorite.file.id]?.isDirectory != false && cursor != null) {
        require(seen.add(cursor), '文件列表分页已失效，请刷新');
        final next = await cloud.listPage(
          session,
          trail.last.$1,
          cursor: cursor,
        );
        for (final file in next.files) {
          files[file.id] = file;
        }
        cursor = next.nextCursor;
      }
      require(
        files[favorite.file.id]?.isDirectory == false,
        '收藏的文件已移动、删除或分享已失效',
      );
    }
    // The location is already usable. Recent-use bookkeeping must not hold
    // the file list behind an unrelated download snapshot write.
    final openedAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(
      store
          .change((draft) {
            final favorites = draft.list('cloudFavorites');
            final index = favorites.indexWhere(
              (item) => item.str('id') == favorite.id,
            );
            // A delayed save must never recreate a removed favorite or account.
            if (index < 0) return;
            var timestamp = openedAt;
            for (final item in favorites) {
              if (item.integer('lastOpenedAt') >= timestamp) {
                timestamp = item.integer('lastOpenedAt') + 1;
              }
            }
            favorites[index] = {...favorites[index], 'lastOpenedAt': timestamp};
            draft['cloudFavorites'] = favorites;
          })
          .catchError((Object error, StackTrace stack) {
            DiagnosticLog.error(
              'favorite.recent_save_failed',
              error,
              stack,
              fields: {'platform': session.platform.name},
            );
          }),
    );
    return (
      session: session,
      trail: trail,
      files: files.values.toList(),
      cursor: cursor,
      highlight: favorite.file.isDirectory ? null : favorite.file.id,
    );
  });
}
