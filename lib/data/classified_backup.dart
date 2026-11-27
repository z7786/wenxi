import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../core/app_version.dart';
import '../core/json.dart';
import '../domain/background.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import '../domain/resource_search.dart';
import '../domain/settings.dart';
import '../domain/torrent.dart';
import 'backgrounds.dart';
import 'backup.dart';
import 'cloud_favorites.dart';
import 'http.dart';
import 'state_store.dart';

const backupSizeLimit = 16 * 1024 * 1024;

enum BackupCategory {
  settings('应用设置', '界面、下载参数与浏览偏好，不含本机目录'),
  appearance('外观设置', '背景透明度与模糊等设置，不包含背景图片'),
  accounts('网盘账号', '选中账号的登录信息，可设置密码保护'),
  favorites('收藏', '网盘与分享收藏、文件夹分类与排序'),
  playback('播放数据', '播放器偏好、云端与 BT 播放记录'),
  search('搜索配置', '来源排序、筛选与隐私偏好'),
  history('解析与搜索历史', '解析记录、搜索词与网盘搜索历史');

  const BackupCategory(this.label, this.description);
  final String label, description;
}

String backupAccountKey(String platform, String id) => '$platform/$id';
Json _clone(Json value) => asJson(jsonDecode(jsonEncode(value)));

class BackupPreview {
  BackupPreview(this.payload, {this.legacy = false});
  final Json payload;
  final bool legacy;
  List<String> get unknownCategories => payload
      .obj('categories')
      .keys
      .where((key) => !BackupCategory.values.any((c) => c.name == key))
      .toList();
  Set<BackupCategory> get categories => {
    for (final category in BackupCategory.values)
      if (payload.obj('categories').containsKey(category.name)) category,
  };
  List<Json> get accounts => payload.list('accountReferences');
  int get createdAt => payload.integer('createdAt');
  Json content(BackupCategory category) =>
      payload.obj('categories').obj(category.name);
  int count(BackupCategory category) => switch (category) {
    BackupCategory.accounts => content(category).list('cloudAccounts').length,
    BackupCategory.favorites => content(category).list('cloudFavorites').length,
    BackupCategory.playback => content(category).obj('playbackHistory').length,
    BackupCategory.appearance => content(category).obj('background').length,
    BackupCategory.history =>
      content(category).list('history').length +
          (content(category)['resourceSearchHistory'] as List? ?? []).length +
          content(category).obj('cloudSearchHistory').length,
    _ => content(category).length,
  };
}

class BackupRestoreResult {
  const BackupRestoreResult(this.accounts, this.pending);
  final int accounts, pending;
}

/// Portable categories are independent of the local StateStore format.
class ClassifiedBackupRepository {
  ClassifiedBackupRepository(this.store, {this.backgrounds});
  final StateStore store;
  final BackgroundRepository? backgrounds;
  static final _gates = Expando<AsyncGate>('backup.restore');
  AsyncGate get _gate => _gates[store] ??= AsyncGate();
  static const defaults = {
    BackupCategory.settings,
    BackupCategory.favorites,
    BackupCategory.search,
  };
  static const _keys = {
    BackupCategory.settings: ['settings'],
    BackupCategory.appearance: ['settings'],
    BackupCategory.accounts: [
      'cloudAccounts',
      'activeCloudAccounts',
      'credentials',
      'secrets',
    ],
    BackupCategory.favorites: [
      'cloudFavorites',
      'cloudFavoriteSort',
      'cloudFavoriteFolders',
    ],
    BackupCategory.playback: [
      'playbackPreferences',
      'playbackHistory',
      'playbackHistoryHidden',
      'playbackTorrents',
    ],
    BackupCategory.search: ['resourceSearch'],
    BackupCategory.history: [
      'history',
      'resourceSearchHistory',
      'cloudSearchHistory',
    ],
  };
  static const _searchKeys = {
    'incognito',
    'preferSupported',
    'cloudPriority',
    'disabledClouds',
  };

  List<Json> get pending => store.data.list('backupPending');
  bool get canUndo => store.data['backupUndo'] is Map;

  Future<Uint8List> create({
    required Set<BackupCategory> categories,
    String password = '',
    Set<String>? accountKeys,
  }) async {
    require(categories.isNotEmpty, '请至少选择一类备份内容');
    require(password.isEmpty || password.length >= 6, '备份密码至少需要 6 位');
    final snapshot = StateStore.memory(store.data);
    Vault.migrateDraft(snapshot.data);
    final vault = Vault(snapshot), data = snapshot.data;
    final refs = <String, Json>{};
    final accounts = <Json>[];
    for (final platform in CloudPlatform.values) {
      for (final profile in vault.profiles(platform)) {
        final key = backupAccountKey(platform.key, profile.id);
        refs[key] = {
          'platform': platform.key,
          'id': profile.id,
          'name': profile.name,
        };
        if (accountKeys != null && !accountKeys.contains(key)) continue;
        final record = data
            .obj('cloudAccounts')
            .obj(platform.key)
            .obj(profile.id);
        accounts.add({
          'id': profile.id,
          'platform': platform.key,
          'name': profile.customName,
          'nameIsCustom': profile.customName.isNotEmpty,
          'credential': vault.credentialFor(platform, profile.id)!.toJson(),
          'secrets': {
            for (final entry in record.obj('secrets').entries)
              if (backupSecretKeys.contains(entry.key)) entry.key: entry.value,
          },
        });
      }
    }
    final sections = <String, dynamic>{};
    final settings = AppSettings.fromJson(data.obj('settings')).toJson()
      ..remove('destination');
    final background = BackgroundSettings.fromJson(settings.obj('background'));
    if (categories.contains(BackupCategory.settings)) {
      sections['settings'] = {'settings': settings..remove('background')};
    }
    if (categories.contains(BackupCategory.appearance)) {
      sections['appearance'] = {
        'background': background.withoutImages().toJson(),
      };
    }
    if (categories.contains(BackupCategory.accounts)) {
      sections['accounts'] = {
        'cloudAccounts': accounts,
        'activeCloudAccounts': {
          for (final account in accounts)
            if (vault.activeAccountId(
                  CloudPlatform.fromKey(account.str('platform'))!,
                ) ==
                account.str('id'))
              account.str('platform'): account.str('id'),
        },
      };
    }
    if (categories.contains(BackupCategory.favorites)) {
      sections['favorites'] = {
        'cloudFavorites': [
          for (final item in data.list('cloudFavorites'))
            CloudFavorite.fromJson(item).toJson(),
        ],
        'cloudFavoriteSort': data.str('cloudFavoriteSort'),
        'cloudFavoriteFolders': data.list('cloudFavoriteFolders'),
      };
    }
    if (categories.contains(BackupCategory.playback)) {
      final history = <String, dynamic>{};
      for (final entry in data.obj('playbackHistory').entries) {
        final bookmark = PlaybackBookmark.fromJson(asJson(entry.value));
        final source = bookmark.source;
        if (source == null ||
            {
              PlaybackSourceKind.local,
              PlaybackSourceKind.download,
            }.contains(source.kind)) {
          continue;
        }
        final raw = bookmark.toJson();
        if (source.cloud case final origin?) {
          final owner =
              origin.session.accountId ??
              (origin.accountRevision == null
                  ? null
                  : vault.accountForRevision(
                      origin.session.platform,
                      origin.accountRevision!,
                    ));
          final serialized = raw.obj('source'),
              savedOrigin = serialized.obj('origin');
          savedOrigin['session'] = {
            ...origin.session.toJson(),
            'metadata': {
              ...origin.session.spaceMetadata,
              'accountId': owner ?? '',
            },
          };
          serialized['origin'] = savedOrigin;
          raw['source'] = serialized;
        }
        history[entry.key] = raw;
      }
      sections['playback'] = {
        'playbackPreferences': PlaybackPreferences.fromJson(
          data.obj('playbackPreferences'),
        ).toJson(),
        'playbackHistory': history,
        'playbackHistoryHidden': data.boolean('playbackHistoryHidden'),
        'playbackTorrents': {
          for (final value in history.values)
            if (asJson(value).obj('source').str('kind') == 'torrent')
              asJson(value).obj('source').str('hash'): data
                  .obj('playbackTorrents')
                  .obj(asJson(value).obj('source').str('hash')),
        }..removeWhere((_, value) => asJson(value).isEmpty),
      };
    }
    if (categories.contains(BackupCategory.search)) {
      sections['search'] = {
        'resourceSearch': {
          for (final key in _searchKeys)
            if (data.obj('resourceSearch').containsKey(key))
              key: data.obj('resourceSearch')[key],
        },
      };
    }
    if (categories.contains(BackupCategory.history)) {
      sections['history'] = {
        for (final key in _keys[BackupCategory.history]!)
          if (data.containsKey(key)) key: data[key],
      };
    }
    for (final item in data.list('backupPending')) {
      final ref = item.obj('account');
      refs[backupAccountKey(ref.str('platform'), ref.str('id'))] = ref;
      for (final category in [
        BackupCategory.favorites,
        BackupCategory.playback,
        BackupCategory.history,
      ]) {
        if (!categories.contains(category)) continue;
        final target = asJson(sections[category.name]),
            source = item.obj('categories').obj(category.name);
        if (category == BackupCategory.favorites) {
          target['cloudFavorites'] = [
            ...target.list('cloudFavorites'),
            ...source.list('cloudFavorites'),
          ];
        } else {
          final key = category == BackupCategory.playback
              ? 'playbackHistory'
              : 'cloudSearchHistory';
          target[key] = {...target.obj(key), ...source.obj(key)};
        }
        sections[category.name] = target;
      }
    }
    final payload = <String, dynamic>{
      'schema': 1,
      'package': 'com.asterlink.app',
      'classifiedVersion': 1,
      'appVersion': applicationVersion,
      'id': newId(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'accountReferences': _references(sections, refs).values.toList(),
      'categories': sections,
    };
    for (final category in categories) {
      _validate(category, asJson(sections[category.name]));
    }
    final bytes = password.isEmpty
        ? await compute(encodePlainBackup, payload)
        : await compute(encryptBackup, (payload, password));
    require(bytes.length <= backupSizeLimit, '备份文件过大，请减少分类或账号');
    RequestScope.checkpoint();
    return bytes;
  }

  Future<BackupPreview> preview(Uint8List bytes, String password) async {
    var payload = await compute(decryptBackup, (bytes, password));
    final legacy = !payload.containsKey('classifiedVersion');
    if (legacy) {
      // Run the existing importer against isolated state to validate old accounts.
      final temporary = StateStore.memory();
      await BackupRepository(temporary).restore(bytes, password);
      final categories = <String, dynamic>{};
      if (payload.containsKey('settings')) {
        categories['settings'] = {
          'settings': payload.obj('settings')..remove('background'),
        };
      }
      if (payload.obj('settings').containsKey('background')) {
        categories['appearance'] = {
          'background': payload.obj('settings')['background'],
          'backgroundImages': payload['backgroundImages'] ?? {},
        };
      }
      if (payload.containsKey('cloudAccounts') ||
          payload.containsKey('credentials')) {
        categories['accounts'] = {
          'cloudAccounts': [
            for (final platform in CloudPlatform.values)
              for (final profile in Vault(temporary).profiles(platform))
                {
                  ...temporary.data
                      .obj('cloudAccounts')
                      .obj(platform.key)
                      .obj(profile.id),
                  'platform': platform.key,
                  'id': profile.id,
                },
          ],
          'activeCloudAccounts': temporary.data.obj('activeCloudAccounts'),
        };
      }
      if (payload.containsKey('cloudFavorites')) {
        categories['favorites'] = {
          'cloudFavorites': payload['cloudFavorites'],
          'cloudFavoriteSort': payload['cloudFavoriteSort'],
          if (payload.containsKey('cloudFavoriteFolders'))
            'cloudFavoriteFolders': payload['cloudFavoriteFolders'],
        };
      }
      payload = {
        'schema': 1,
        'package': 'com.asterlink.app',
        'classifiedVersion': 1,
        'createdAt': payload['createdAt'],
        'categories': categories,
        'accountReferences': [
          for (final item in asJson(
            categories['accounts'],
          ).list('cloudAccounts'))
            {
              'id': item['id'],
              'platform': item['platform'],
              'name': item['name'],
            },
        ],
      };
    }
    require(payload.integer('classifiedVersion') == 1, '此分类备份版本暂不支持，请更新应用');
    require(payload['categories'] is Map, '备份分类清单格式错误');
    final references = _references(payload.obj('categories'), {
      for (final ref in payload.list('accountReferences'))
        backupAccountKey(ref.str('platform'), ref.str('id')): ref,
    });
    payload['accountReferences'] = references.values.toList();
    final result = BackupPreview(payload, legacy: legacy);
    require(result.categories.isNotEmpty, '没有可恢复的分类');
    for (final category in result.categories) {
      require(payload.obj('categories')[category.name] is Map, '备份分类内容已损坏');
      _validate(category, result.content(category));
    }
    RequestScope.checkpoint();
    return result;
  }

  static Map<String, Json> _references(Json sections, Map<String, Json> known) {
    final used = <String, Json>{};
    void add(String platform, String id) {
      final key = backupAccountKey(platform, id);
      used[key] = known[key] ?? {'platform': platform, 'id': id, 'name': id};
    }

    for (final account in sections.obj('accounts').list('cloudAccounts')) {
      add(account.str('platform'), account.str('id'));
    }
    for (final favorite in sections.obj('favorites').list('cloudFavorites')) {
      final session = BrowseSession.fromJson(favorite.obj('session'));
      add(session.platform.key, session.accountId ?? '');
    }
    for (final value
        in sections.obj('playback').obj('playbackHistory').values) {
      final source = asJson(value).obj('source');
      if (source.str('kind') != 'cloud') continue;
      final session = BrowseSession.fromJson(
        source.obj('origin').obj('session'),
      );
      add(session.platform.key, session.accountId ?? '');
    }
    for (final key in sections.obj('history').obj('cloudSearchHistory').keys) {
      final parts = jsonDecode(key);
      require(parts is List && parts.length == 6, '网盘搜索历史格式错误');
      add(parts[0].toString(), parts[1].toString());
    }
    return used;
  }

  static void _validate(BackupCategory category, Json section) {
    void list(String key, int limit) {
      if (!section.containsKey(key)) return;
      require(
        section[key] is List &&
            (section[key] as List).length <= limit &&
            (section[key] as List).every((e) => e is Map),
        '备份${category.label}格式错误',
      );
    }

    void map(String key, [int limit = 2000]) {
      if (section.containsKey(key)) {
        require(
          section[key] is Map && (section[key] as Map).length <= limit,
          '备份${category.label}格式错误',
        );
      }
    }

    switch (category) {
      case BackupCategory.settings:
        map('settings');
        AppSettings.fromJson(section.obj('settings'));
      case BackupCategory.appearance:
        map('background');
        map('backgroundImages');
      case BackupCategory.accounts:
        list('cloudAccounts', 1000);
        map('activeCloudAccounts');
        final seen = <String>{};
        for (final item in section.list('cloudAccounts')) {
          require(
            CloudPlatform.fromKey(item.str('platform'))?.requiresAccount ==
                    true &&
                RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(item.str('id')) &&
                seen.add(
                  backupAccountKey(item.str('platform'), item.str('id')),
                ) &&
                item.obj('credential')['fields'] is Map,
            '备份账号格式错误',
          );
        }
      case BackupCategory.favorites:
        list('cloudFavorites', 2000);
        list('cloudFavoriteFolders', 200);
        CloudFavorites.mergeFolders({}, section);
        for (final item in section.list('cloudFavorites')) {
          final favorite = CloudFavorite.fromJson(item);
          require(
            favorite.id.isNotEmpty &&
                favorite.file.id.isNotEmpty &&
                favorite.trail.isNotEmpty &&
                favorite.trail.length <= 64 &&
                (!favorite.isShareLink ||
                    favorite.session.mode == BrowseMode.share &&
                        favorite.session.sourceLink != null &&
                        favorite.file.isDirectory),
            '备份收藏目录不完整',
          );
        }
      case BackupCategory.playback:
        map('playbackPreferences');
        map('playbackHistory', 2000);
        map('playbackTorrents', 200);
        for (final entry in section.obj('playbackTorrents').entries) {
          final torrent = asJson(entry.value);
          require(
            RegExp(r'^[0-9a-f]{40}$').hasMatch(entry.key) &&
                torrent.str('hash') == entry.key &&
                torrent.str('data').startsWith(torrentDataPrefix) &&
                torrent.str('data').length <= maxTorrentBytes * 4 ~/ 3 + 100 &&
                torrent['files'] is List &&
                torrent.list('files').length <= maxTorrentFiles,
            '备份种子信息无效',
          );
          require(
            base64Decode(
                  torrent.str('data').substring(torrentDataPrefix.length),
                ).length <=
                maxTorrentBytes,
            '备份种子信息过大',
          );
          for (final item in torrent.list('files')) {
            require(
              item.integer('index', -1) >= 0 &&
                  item.integer('size', -1) >= 0 &&
                  item.str('path').isNotEmpty &&
                  !item.str('path').startsWith('/') &&
                  !item.str('path').contains('\\') &&
                  !item.str('path').split('/').contains('..'),
              '备份种子路径无效',
            );
          }
        }
        for (final entry in section.obj('playbackHistory').values) {
          require(entry is Map, '备份播放记录格式错误');
          final raw = asJson(entry),
              source = PlaybackSource.tryFromJson(raw['source']);
          require(
            source != null &&
                {
                  PlaybackSourceKind.cloud,
                  PlaybackSourceKind.torrent,
                }.contains(source.kind),
            '备份播放来源不可迁移',
          );
        }
      case BackupCategory.search:
        map('resourceSearch');
      case BackupCategory.history:
        list('history', 300);
        map('cloudSearchHistory', 80);
        require(
          section['resourceSearchHistory'] == null ||
              section['resourceSearchHistory'] is List &&
                  (section['resourceSearchHistory'] as List).length <=
                      ResourceSearchHistory.limit &&
                  (section['resourceSearchHistory'] as List).every(
                    (e) => e is String && e.length <= 120,
                  ),
          '备份搜索词格式错误',
        );
        for (final entry in section.obj('cloudSearchHistory').entries) {
          final scope = jsonDecode(entry.key);
          require(
            scope is List &&
                scope.length == 6 &&
                scope.every((e) => e is String) &&
                CloudPlatform.fromKey(scope[0] as String) != null &&
                entry.value is List &&
                (entry.value as List).length <= 12 &&
                (entry.value as List).every(
                  (e) => e is String && e.length <= 120,
                ),
            '网盘搜索历史格式错误',
          );
        }
    }
  }

  Future<BackupRestoreResult> restore(
    BackupPreview preview, {
    required Set<BackupCategory> categories,
    Map<String, String> bindings = const {},
    bool replaceAccounts = false,
  }) => _gate.run(() async {
    require(
      categories.isNotEmpty && categories.every(preview.categories.contains),
      '请选择备份中存在的分类',
    );
    final selected = {
      for (final c in categories) c.name: _clone(preview.content(c)),
    };
    for (final c in categories) {
      _validate(c, asJson(selected[c.name]));
    }
    Object? imageDraft;
    try {
      final oldSettings = jsonEncode(store.data['settings']);
      final oldBackground = BackgroundSettings.fromJson(
        store.data.obj('settings').obj('background'),
      );
      Json? oldImages;
      BackgroundSettings? restoredBackground;
      if (categories.contains(BackupCategory.appearance) ||
          categories.contains(BackupCategory.settings)) {
        imageDraft = backgrounds?.beginDraft();
        oldImages = await backgrounds?.exportImages(oldBackground);
      }
      if (categories.contains(BackupCategory.appearance)) {
        final appearance = asJson(selected['appearance']);
        final imported = BackgroundSettings.fromJson(
          appearance.obj('background'),
        );
        require(backgrounds != null || !imported.hasImage, '当前环境无法恢复背景图片');
        restoredBackground = backgrounds == null
            ? imported
            : await backgrounds!.restoreImages(
                imported,
                appearance['backgroundImages'],
                imageDraft!,
              );
      }
      RequestScope.checkpoint();
      return await store.change((draft) {
        RequestScope.checkpoint();
        if (categories.contains(BackupCategory.appearance) ||
            categories.contains(BackupCategory.settings)) {
          require(
            jsonEncode(draft['settings']) == oldSettings,
            '设置已变化，请重新确认恢复',
          );
        }
        final keys = {...categories.expand((c) => _keys[c]!), 'backupPending'};
        final undo = {
          'keys': keys.toList(),
          'values': _clone({
            for (final key in keys)
              if (draft.containsKey(key)) key: draft[key],
          }),
          'backgroundImages': ?oldImages,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        };
        final result = _merge(
          draft,
          BackupPreview({...preview.payload, 'categories': selected}),
          categories,
          bindings,
          replaceAccounts,
        );
        if (restoredBackground != null) {
          draft['settings'] = {
            ...draft.obj('settings'),
            'background': restoredBackground.toJson(),
          };
        }
        draft['backupUndo'] = undo;
        return result;
      }, recoveryPassword: '');
    } finally {
      if (imageDraft != null) await backgrounds!.endDraft(imageDraft);
    }
  });

  BackupRestoreResult _merge(
    Json draft,
    BackupPreview preview,
    Set<BackupCategory> categories,
    Map<String, String> bindings,
    bool replaceAccounts,
  ) {
    Vault.migrateDraft(draft);
    final importedIds = <String, String>{};
    var restoredAccounts = 0;
    if (categories.contains(BackupCategory.accounts)) {
      final all = draft.obj('cloudAccounts');
      for (final account
          in preview.content(BackupCategory.accounts).list('cloudAccounts')) {
        final platform = CloudPlatform.fromKey(account.str('platform'))!;
        final key = backupAccountKey(platform.key, account.str('id'));
        final id = bindings[key] ?? account.str('id');
        require(RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id), '账号关联无效');
        final records = all.obj(platform.key);
        // Legacy IDs are shared across installations: never infer identity from them.
        final actualId = bindings.containsKey(key) || !id.startsWith('legacy-')
            ? id
            : 'backup-${sha256.convert(utf8.encode(jsonEncode([platform.key, id, account.obj('credential').obj('fields')]))).toString().substring(0, 32)}';
        importedIds[key] = actualId;
        if (records.obj(actualId)['credential'] != null && !replaceAccounts) {
          continue;
        }
        var revision = DateTime.now().millisecondsSinceEpoch;
        for (final value in records.values) {
          final previous = asJson(value).obj('credential').integer('updatedAt');
          if (revision <= previous) revision = previous + 1;
        }
        records[actualId] = {
          ...Map<String, dynamic>.of(account)
            ..remove('platform')
            ..remove('id'),
          'secrets': {
            for (final entry in account.obj('secrets').entries)
              if (backupSecretKeys.contains(entry.key) &&
                  Vault.accountSecret(platform, entry.key))
                entry.key: entry.value.toString(),
          },
          'credential': {...account.obj('credential'), 'updatedAt': revision},
        };
        all[platform.key] = records;
        restoredAccounts++;
      }
      draft['cloudAccounts'] = all;
      for (final platform in CloudPlatform.values) {
        final old = Vault.activeIdIn(draft, platform);
        final savedId = preview
            .content(BackupCategory.accounts)
            .obj('activeCloudAccounts')
            .str(platform.key);
        final first =
            importedIds[backupAccountKey(platform.key, savedId)] ??
            all.obj(platform.key).keys.firstOrNull;
        if (old != null || first != null) {
          Vault.activateDraft(draft, platform, old ?? first);
        }
      }
    }
    String? owner(String platform, String id) {
      final p = CloudPlatform.fromKey(platform);
      require(p != null, '备份网盘类型无效');
      if (!p!.requiresAccount && id.isEmpty) return '';
      final key = backupAccountKey(platform, id);
      final mapped = bindings[key] ?? importedIds[key];
      if (mapped != null) {
        require(Vault.credentialIn(draft, p, mapped) != null, '关联账号已移除，请重新选择');
        return mapped;
      }
      if (id.isNotEmpty &&
          !id.startsWith('legacy-') &&
          Vault.credentialIn(draft, p, id) != null) {
        return id;
      }
      return null;
    }

    final pendingByAccount = {
      for (final item in draft.list('backupPending'))
        backupAccountKey(
          item.obj('account').str('platform'),
          item.obj('account').str('id'),
        ): item,
    };
    void defer(
      String platform,
      String id,
      BackupCategory category,
      String field,
      String recordId,
      Json? value, {
      Object? rawValue,
    }) {
      final key = backupAccountKey(platform, id);
      final record =
          pendingByAccount[key] ??
          {
            'account':
                preview.accounts
                    .where(
                      (a) => a.str('platform') == platform && a.str('id') == id,
                    )
                    .firstOrNull ??
                {'platform': platform, 'id': id, 'name': id},
            'categories': <String, dynamic>{},
          };
      final sections = record.obj('categories'),
          section = sections.obj(category.name);
      if (field == 'cloudFavorites') {
        section[field] = {
          ...{for (final f in section.list(field)) f.str('id'): f},
          recordId: value,
        }.values.toList();
      } else {
        section[field] = {...section.obj(field), recordId: rawValue ?? value};
      }
      sections[category.name] = section;
      record['categories'] = sections;
      pendingByAccount[key] = record;
    }

    if (categories.contains(BackupCategory.settings)) {
      final current = draft.obj('settings'),
          incoming = preview.content(BackupCategory.settings).obj('settings')
            ..remove('destination')
            ..remove('background');
      draft['settings'] = AppSettings.fromJson({
        ...current,
        ...incoming,
      }).toJson();
    }
    if (categories.contains(BackupCategory.search)) {
      final incoming = preview
          .content(BackupCategory.search)
          .obj('resourceSearch');
      draft['resourceSearch'] = {
        ...draft.obj('resourceSearch'),
        for (final key in _searchKeys)
          if (incoming.containsKey(key)) key: incoming[key],
      };
    }
    if (categories.contains(BackupCategory.favorites)) {
      final section = preview.content(BackupCategory.favorites),
          merged = {
            for (final f in draft.list('cloudFavorites')) f.str('id'): f,
          };
      for (final raw in section.list('cloudFavorites')) {
        final favorite = CloudFavorite.fromJson(raw),
            session = favorite.session;
        final id = owner(session.platform.key, session.accountId ?? '');
        if (id == null) {
          defer(
            session.platform.key,
            session.accountId ?? '',
            BackupCategory.favorites,
            'cloudFavorites',
            favorite.id,
            raw,
          );
          continue;
        }
        final bound = session.withAccount(id);
        final newId = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  bound.platform.key,
                  if (favorite.isShareLink) 'share-link',
                  bound.accountId,
                  bound.mode.name,
                  bound.familyId,
                  if (bound.personalSpaceId.isNotEmpty) bound.personalSpaceId,
                  bound.sourceLink?.shareId ?? bound.sourceLink?.url ?? '',
                  favorite.file.id,
                  favorite.file.isDirectory,
                ]),
              ),
            )
            .toString();
        final value = {
          ...favorite.toJson(),
          'id': newId,
          'accountId': id,
          'session': bound.toJson(),
        };
        // Keep the existing name, position and pin when restoring the same favorite.
        merged.putIfAbsent(newId, () => value);
      }
      require(merged.length <= 2000, '合并后收藏超过 2000 项，请先清理收藏');
      CloudFavorites.mergeFolders(draft, section);
      draft['cloudFavorites'] = merged.values.toList();
      if (section.containsKey('cloudFavoriteSort')) {
        draft['cloudFavoriteSort'] = CloudFavoriteSort.fromName(
          section.str('cloudFavoriteSort'),
        ).name;
      }
    }
    if (categories.contains(BackupCategory.playback)) {
      final section = preview.content(BackupCategory.playback),
          history = draft.obj('playbackHistory');
      for (final entry in section.obj('playbackHistory').entries) {
        final raw = asJson(entry.value),
            source = raw.obj('source'),
            origin = source.obj('origin');
        var key = entry.key;
        if (source.str('kind') == 'cloud') {
          final session = BrowseSession.fromJson(origin.obj('session'));
          final id = owner(session.platform.key, session.accountId ?? '');
          if (id == null) {
            defer(
              session.platform.key,
              session.accountId ?? '',
              BackupCategory.playback,
              'playbackHistory',
              key,
              raw,
            );
            continue;
          }
          final bound = session.withAccount(id),
              revision = Vault.credentialIn(
                draft,
                session.platform,
                id,
              )?.updatedAt;
          source['origin'] = {
            ...origin,
            'session': bound.toJson(),
            'accountRevision': revision,
          };
          raw['source'] = source;
          key = cloudPlaybackKey(
            bound,
            CloudFile.fromJson(origin.obj('file')),
            revision,
          );
        }
        if (!history.containsKey(key) ||
            raw.integer('updatedAt') > history.obj(key).integer('updatedAt')) {
          history[key] = raw;
        }
      }
      final entries = history.entries.toList()
        ..sort(
          (a, b) => asJson(b.value)
              .integer('updatedAt')
              .compareTo(asJson(a.value).integer('updatedAt')),
        );
      draft['playbackHistory'] = Map.fromEntries(entries.take(200));
      if (section.containsKey('playbackTorrents')) {
        final used = draft
            .obj('playbackHistory')
            .values
            .map((e) => asJson(e).obj('source').str('hash'))
            .toSet();
        draft['playbackTorrents'] = {
          ...draft.obj('playbackTorrents'),
          ...section.obj('playbackTorrents'),
        }..removeWhere((key, _) => !used.contains(key));
        require(
          jsonEncode(draft['playbackTorrents']).length <= backupSizeLimit,
          '合并后的种子信息过大，请先清理播放历史',
        );
      }
      if (section.containsKey('playbackPreferences')) {
        draft['playbackPreferences'] = PlaybackPreferences.fromJson(
          section.obj('playbackPreferences'),
        ).toJson();
      }
      if (section.containsKey('playbackHistoryHidden')) {
        draft['playbackHistoryHidden'] = section.boolean(
          'playbackHistoryHidden',
        );
      }
    }
    if (categories.contains(BackupCategory.history)) {
      final section = preview.content(BackupCategory.history);
      if (section.containsKey('history')) {
        final merged = {
          for (final item in [
            ...section.list('history'),
            ...draft.list('history'),
          ])
            item.str('id'): item,
        };
        final items = merged.values.toList()
          ..sort(
            (a, b) => b.integer('createdAt').compareTo(a.integer('createdAt')),
          );
        draft['history'] = items.take(300).toList();
      }
      if (section.containsKey('resourceSearchHistory')) {
        draft['resourceSearchHistory'] = ResourceSearchHistory.read([
          ...ResourceSearchHistory.read(draft['resourceSearchHistory']),
          ...ResourceSearchHistory.read(section['resourceSearchHistory']),
        ]);
      }
      final searches = draft.obj('cloudSearchHistory');
      for (final entry in section.obj('cloudSearchHistory').entries) {
        final scope = jsonDecode(entry.key) as List;
        final id = owner(scope[0] as String, scope[1] as String);
        if (id == null) {
          defer(
            scope[0] as String,
            scope[1] as String,
            BackupCategory.history,
            'cloudSearchHistory',
            entry.key,
            null,
            rawValue: entry.value,
          );
          continue;
        }
        scope[1] = id;
        final key = jsonEncode(scope);
        searches[key] = {
          ...((searches[key] as List?) ?? []),
          ...(entry.value as List),
        }.take(12).toList();
      }
      draft['cloudSearchHistory'] = Map.fromEntries(
        searches.entries.toList().reversed.take(80).toList().reversed,
      );
    }
    // A binding consumes only the categories restored in this operation.
    for (final key in bindings.keys) {
      if (preview.payload.str('bindingPendingKey') != key) continue;
      final record = pendingByAccount[key];
      if (record == null) continue;
      final remaining = record.obj('categories')
        ..removeWhere((key, _) => categories.any((c) => c.name == key));
      if (remaining.isEmpty) {
        pendingByAccount.remove(key);
      } else {
        record['categories'] = remaining;
      }
    }
    draft['backupPending'] = pendingByAccount.values.toList();
    require(
      utf8.encode(jsonEncode(draft['backupPending'])).length <= backupSizeLimit,
      '待关联数据过多，请先关联账号',
    );
    return BackupRestoreResult(restoredAccounts, pendingByAccount.length);
  }

  Future<BackupRestoreResult> bindPending(Json item, String targetId) {
    final reference = item.obj('account');
    final preview = BackupPreview({
      'categories': item.obj('categories'),
      'accountReferences': [reference],
      'bindingPendingKey': backupAccountKey(
        reference.str('platform'),
        reference.str('id'),
      ),
    });
    return restore(
      preview,
      categories: preview.categories,
      bindings: {
        backupAccountKey(reference.str('platform'), reference.str('id')):
            targetId,
      },
    );
  }

  Future<void> undo() => _gate.run(() async {
    final saved = _clone(store.data.obj('backupUndo'));
    require(saved['keys'] is List && saved['values'] is Map, '没有可回退的恢复记录');
    Object? imageDraft;
    try {
      final values = saved.obj('values');
      if (saved.containsKey('backgroundImages') && backgrounds != null) {
        imageDraft = backgrounds!.beginDraft();
        await backgrounds!.restoreImages(
          BackgroundSettings.fromJson(values.obj('settings').obj('background')),
          saved['backgroundImages'],
          imageDraft,
        );
      }
      RequestScope.checkpoint();
      await store.change((draft) {
        require(
          jsonEncode(draft['backupUndo']) == jsonEncode(saved),
          '回退记录已变化',
        );
        for (final key in (saved['keys'] as List).cast<String>()) {
          if (values.containsKey(key)) {
            draft[key] = values[key];
          } else {
            draft.remove(key);
          }
        }
        // Advance account revisions when returning to earlier credentials.
        if ((saved['keys'] as List).contains('cloudAccounts')) {
          Vault.migrateDraft(draft);
          final all = draft.obj('cloudAccounts');
          final revisions = <String, int>{};
          final previousOwners = <String, String>{};
          var revision = DateTime.now().millisecondsSinceEpoch;
          for (final records in store.data.obj('cloudAccounts').values) {
            for (final record in asJson(records).values) {
              final previous = asJson(
                record,
              ).obj('credential').integer('updatedAt');
              if (revision <= previous) revision = previous + 1;
            }
          }
          for (final platform in CloudPlatform.values) {
            final records = all.obj(platform.key);
            for (final id in records.keys.toList()) {
              final record = records.obj(id),
                  credential = record.obj('credential');
              if (credential.isEmpty) continue;
              previousOwners['${platform.key}/${credential.integer('updatedAt')}'] =
                  id;
              revision = revision > credential.integer('updatedAt')
                  ? revision + 1
                  : credential.integer('updatedAt') + 1;
              records[id] = {
                ...record,
                'credential': {...credential, 'updatedAt': revision},
              };
              revisions[backupAccountKey(platform.key, id)] = revision;
            }
            if (records.isNotEmpty) all[platform.key] = records;
          }
          draft['cloudAccounts'] = all;
          for (final platform in CloudPlatform.values) {
            final id = Vault.activeIdIn(draft, platform);
            if (id != null) Vault.activateDraft(draft, platform, id);
          }
          // Restored playback records must reference the newly issued revision.
          if ((saved['keys'] as List).contains('playbackHistory')) {
            final history = <String, dynamic>{};
            for (final entry in draft.obj('playbackHistory').entries) {
              final record = asJson(entry.value), source = record.obj('source');
              var key = entry.key;
              if (source.str('kind') == 'cloud') {
                final origin = source.obj('origin');
                var session = BrowseSession.fromJson(
                  source.obj('origin').obj('session'),
                );
                if (session.accountId?.isNotEmpty != true) {
                  session = session.withAccount(
                    previousOwners['${session.platform.key}/${origin.integer('accountRevision')}'],
                  );
                }
                final revision =
                    revisions[backupAccountKey(
                      session.platform.key,
                      session.accountId ?? '',
                    )];
                if (revision != null) {
                  source['origin'] = {
                    ...origin,
                    'session': session.toJson(),
                    'accountRevision': revision,
                  };
                  record['source'] = source;
                  key = cloudPlaybackKey(
                    session,
                    CloudFile.fromJson(origin.obj('file')),
                    revision,
                  );
                }
              }
              history[key] = record;
            }
            draft['playbackHistory'] = history;
          }
        }
        draft.remove('backupUndo');
      }, recoveryPassword: '');
    } finally {
      if (imageDraft != null) await backgrounds!.endDraft(imageDraft);
    }
  });
}
