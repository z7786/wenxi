import 'dart:convert';
import '../core/json.dart';
import '../domain/models.dart';
import 'state_store.dart';

/// Search terms stay in the app's private local store, scoped to their account.
class CloudSearchHistory {
  const CloudSearchHistory(this.store);
  final StateStore store;
  static const limit = 12;

  String _key(BrowseSession session) => jsonEncode([
    session.platform.key,
    session.accountId ?? '',
    session.mode.name,
    session.familyId,
    session.personalSpaceId,
    session.rootId,
  ]);

  List<String> _read(Json data, String key) {
    final raw = data.obj('cloudSearchHistory')[key];
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty && value.length <= 120)
        .take(limit)
        .toList(growable: false);
  }

  List<String> read(BrowseSession session) => _read(store.data, _key(session));

  Future<void> remember(BrowseSession session, String term) async {
    term = term.trim();
    if (term.isEmpty || term.length > 120) return;
    if (read(session).firstOrNull == term) return;
    final key = _key(session), value = term;
    await store.change((draft) {
      final recent = _read(draft, key);
      final all = draft.obj('cloudSearchHistory')..remove(key);
      while (all.length >= 80) {
        all.remove(all.keys.first);
      }
      all[key] = [
        value,
        ...recent.where((old) => old.toLowerCase() != value.toLowerCase()),
      ].take(limit).toList();
      draft['cloudSearchHistory'] = all;
    });
  }

  Future<void> clear(BrowseSession session) => store.change((draft) {
    draft['cloudSearchHistory'] = draft.obj('cloudSearchHistory')
      ..remove(_key(session));
  });

  Future<void> remove(BrowseSession session, String term) =>
      store.change((draft) {
        final all = draft.obj('cloudSearchHistory'), key = _key(session);
        all[key] = _read(draft, key).where((value) => value != term).toList();
        draft['cloudSearchHistory'] = all;
      });
}
