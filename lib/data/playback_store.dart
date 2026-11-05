import '../core/json.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import 'state_store.dart';

class PlaybackStore {
  PlaybackStore(this.store);
  final StateStore store;
  static final _pendingBookmarks = Expando<Map<String, PlaybackBookmark>>(
    'playback.pending',
  );
  static const historyLimit = 200;
  static const torrentCacheBytes = 16 * 1024 * 1024;
  List<PlaybackRecord> get recent {
    final bookmarks = {
      for (final entry in store.data.obj('playbackHistory').entries)
        if (entry.value is Map)
          entry.key: PlaybackBookmark.fromJson(asJson(entry.value)),
      ...?_pendingBookmarks[store],
    };
    final records = [
      for (final entry in bookmarks.entries)
        PlaybackRecord(entry.key, entry.value),
    ]..sort((a, b) => b.bookmark.updatedAt.compareTo(a.bookmark.updatedAt));
    return records.take(historyLimit).toList();
  }

  PlaybackPreferences get preferences =>
      PlaybackPreferences.fromJson(store.data.obj('playbackPreferences'));
  PlaybackBookmark? bookmark(String key) {
    final pending = _pendingBookmarks[store]?[key];
    if (pending != null) return pending;
    final value = store.data.obj('playbackHistory')[key];
    return value is Map ? PlaybackBookmark.fromJson(asJson(value)) : null;
  }

  Future<void> savePreferences(PlaybackPreferences value) =>
      store.put('playbackPreferences', value.toJson());

  bool remembersFolder(String? key) =>
      key != null &&
      store.data.obj('playbackFolders').obj(key).boolean('enabled', true);

  PlaybackPreferences preferencesFor(String? key) {
    if (!remembersFolder(key)) return preferences;
    final overrides = store.data
        .obj('playbackFolders')
        .obj(key!)
        .obj('preferences');
    return PlaybackPreferences.fromJson({
      ...preferences.toJson(),
      for (final entry in overrides.entries)
        if (playbackFolderFields.contains(entry.key)) entry.key: entry.value,
    });
  }

  PlaybackPlaylistOrder orderFor(String? key) {
    if (!remembersFolder(key)) return PlaybackPlaylistOrder.source;
    final order = store.data.obj('playbackFolders').obj(key!).str('order');
    return PlaybackPlaylistOrder.values.firstWhere(
      (value) => value.name == order,
      orElse: () => PlaybackPlaylistOrder.source,
    );
  }

  Future<void> rememberFolder(String key, bool enabled) =>
      store.change((draft) {
        final folders = draft.obj('playbackFolders');
        final value = folders.obj(key)..['enabled'] = enabled;
        _putFolder(draft, folders, key, value);
      });

  Future<void> saveOrder(String? key, PlaybackPlaylistOrder order) async {
    if (!remembersFolder(key)) return;
    await store.change((draft) {
      final folders = draft.obj('playbackFolders');
      final value = folders.obj(key!)..['order'] = order.name;
      _putFolder(draft, folders, key, value);
    });
  }

  Future<void> saveEffectivePreferences(
    String? key,
    PlaybackPreferences value,
    PlaybackPreferences previous,
  ) => store.change((draft) {
    final global = PlaybackPreferences.fromJson(
      draft.obj('playbackPreferences'),
    ).toJson();
    final folders = draft.obj('playbackFolders');
    final folder = key == null ? <String, dynamic>{} : folders.obj(key);
    final remember = key != null && folder.boolean('enabled', true);
    final overrides = folder.obj('preferences');
    final before = previous.toJson();
    var folderChanged = false;
    for (final entry in value.toJson().entries) {
      if (encoded(entry.value) == encoded(before[entry.key])) continue;
      if (remember && playbackFolderFields.contains(entry.key)) {
        overrides[entry.key] = entry.value;
        folderChanged = true;
      } else {
        global[entry.key] = entry.value;
      }
    }
    draft['playbackPreferences'] = global;
    if (folderChanged) {
      folder['preferences'] = overrides;
      _putFolder(draft, folders, key!, folder);
    }
  });

  static void _putFolder(Json draft, Json folders, String key, Json value) {
    folders.remove(key);
    folders[key] = value;
    draft['playbackFolders'] = Map.fromEntries(
      folders.entries.skip(
        (folders.length - historyLimit).clamp(0, folders.length),
      ),
    );
  }

  VideoGeometry? videoGeometry(String key) {
    final value = store.data.obj('playbackVideoInfo')[key];
    return value is Map ? VideoGeometry.fromJson(asJson(value)) : null;
  }

  Future<void> saveVideoGeometry(String key, VideoGeometry geometry) =>
      store.change((draft) {
        final entries = draft.obj('playbackVideoInfo')..remove(key);
        entries[key] = geometry.toJson();
        draft['playbackVideoInfo'] = Map.fromEntries(
          entries.entries.skip(
            (entries.length - historyLimit).clamp(0, entries.length),
          ),
        );
      });
  Future<void> save(String key, PlaybackBookmark bookmark) {
    // A closing player can return before its durable write finishes. Every
    // PlaybackStore for this device sees the captured progress during that gap.
    final previous = this.bookmark(key);
    final pending = PlaybackBookmark(
      position: bookmark.position,
      duration: bookmark.duration,
      updatedAt: bookmark.updatedAt,
      completed: bookmark.completed,
      name: bookmark.name,
      source: bookmark.source ?? previous?.source,
    );
    final bookmarks = _pendingBookmarks[store] ??= {};
    bookmarks[key] = pending;
    return _save(key, bookmark).whenComplete(() {
      // An older completion must not erase the next player's pending progress.
      if (identical(bookmarks[key], pending)) bookmarks.remove(key);
    });
  }

  Future<void> _save(String key, PlaybackBookmark bookmark) => store.change((
    draft,
  ) {
    final history = draft.obj('playbackHistory');
    final previous = asJson(history[key]);
    history[key] = {
      ...bookmark.toJson(),
      if (bookmark.source == null && previous['source'] is Map)
        'source': previous['source'],
    };
    final entries = history.entries.toList()
      ..sort(
        (a, b) => asJson(
          b.value,
        ).integer('updatedAt').compareTo(asJson(a.value).integer('updatedAt')),
      );
    draft['playbackHistory'] = Map.fromEntries(entries.take(historyLimit));
    final source = bookmark.source;
    if (source?.kind == PlaybackSourceKind.torrent &&
        source!.torrentData.isNotEmpty) {
      final cache = draft.obj('playbackTorrents');
      final previous = asJson(cache.remove(source.torrentHash));
      final files = <int, Json>{
        for (final file in previous.list('files')) file.integer('index'): file,
        for (final file in source.torrentFiles)
          file.index: {
            'index': file.index,
            'path': file.path,
            'size': file.size,
          },
      };
      cache[source.torrentHash] = {
        'hash': source.torrentHash,
        'data': source.torrentData,
        'files': files.values.toList(),
      };
      draft['playbackTorrents'] = cache;
    }
    _pruneTorrents(draft);
  });
  static void _pruneTorrents(Json draft) {
    final used = draft
        .obj('playbackHistory')
        .values
        .map((value) => asJson(value).obj('source'))
        .where((value) => value.str('kind') == 'torrent')
        .map((value) => value.str('hash'))
        .toSet();
    final cache = draft.obj('playbackTorrents')
      ..removeWhere((key, _) => !used.contains(key));
    var bytes = 0;
    final keep = <String>{};
    for (final entry in cache.entries.toList().reversed) {
      final length = asJson(entry.value).str('data').length;
      if (bytes + length > torrentCacheBytes) continue;
      bytes += length;
      keep.add(entry.key);
    }
    cache.removeWhere((key, _) => !keep.contains(key));
    if (cache.isEmpty) {
      draft.remove('playbackTorrents');
    } else {
      draft['playbackTorrents'] = cache;
    }
  }

  Future<void> opened(String key, String name, PlaybackSource? source) async {
    // Legacy callers without a restorable origin keep their existing progress
    // behavior. A newly opened media with an origin is visible immediately.
    if (source == null) return;
    final previous = bookmark(key);
    await save(
      key,
      PlaybackBookmark(
        name: name,
        source: source,
        position: previous?.position ?? Duration.zero,
        duration: previous?.duration ?? Duration.zero,
        completed: previous?.completed ?? false,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> remove(String key) {
    _pendingBookmarks[store]?.remove(key);
    return store.change((draft) {
      draft['playbackHistory'] = draft.obj('playbackHistory')..remove(key);
      draft['playbackVideoInfo'] = draft.obj('playbackVideoInfo')..remove(key);
      _pruneTorrents(draft);
    });
  }

  Future<void> clearHistory() {
    _pendingBookmarks[store]?.clear();
    return store.change((draft) {
      draft['playbackHistory'] = <String, dynamic>{};
      draft.remove('playbackVideoInfo');
      draft.remove('playbackTorrents');
    });
  }
}
