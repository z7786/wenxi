import 'dart:convert';
import '../core/json.dart';
import '../domain/models.dart';
import 'state_store.dart';

/// Remember directory paths, never credentials or an old browsing session.
class CloudSaveLocations {
  CloudSaveLocations(this.store);
  final StateStore store;
  final _pending = <String, Json>{};
  static const _field = 'cloudSaveLocations', _limit = 200;

  String _key(BrowseSession session) => jsonEncode([
    session.platform.key,
    session.accountId,
    session.familyId,
    session.personalSpaceId,
    session.rootId,
  ]);

  bool _hasOwner(Json data, BrowseSession session) =>
      session.mode == BrowseMode.personal &&
      session.accountId?.isNotEmpty == true &&
      Vault.credentialIn(data, session.platform, session.accountId) != null;

  List<(String, String)>? read(BrowseSession session) {
    if (!_hasOwner(store.data, session)) return null;
    final key = _key(session);
    final saved = asJson(_pending[key] ?? store.data.obj(_field)[key]);
    if (saved.str('platform') != session.platform.key ||
        saved.str('accountId') != session.accountId) {
      return null;
    }
    final raw = saved['trail'];
    if (raw is! List || raw.isEmpty || raw.length > 256) return null;
    final trail = <(String, String)>[];
    for (final entry in raw) {
      if (entry is! Map ||
          entry['id'] is! String ||
          entry['name'] is! String ||
          (entry['name'] as String).isEmpty) {
        return null;
      }
      trail.add((entry['id'] as String, entry['name'] as String));
    }
    if (trail.first.$1 != session.rootId ||
        trail.skip(1).any((part) => part.$1.isEmpty) ||
        trail.map((part) => part.$1).toSet().length != trail.length) {
      return null;
    }
    trail[0] = (session.rootId, '全部文件');
    return trail;
  }

  Future<void> remember(
    BrowseSession session,
    List<(String, String)> trail,
  ) async {
    if (!_hasOwner(store.data, session) ||
        trail.isEmpty ||
        trail.length > 256 ||
        trail.first.$1 != session.rootId) {
      return;
    }
    final key = _key(session);
    final value = <String, dynamic>{
      'platform': session.platform.key,
      'accountId': session.accountId,
      'trail': [
        for (final part in trail) {'id': part.$1, 'name': part.$2},
      ],
    };
    if (jsonEncode(_pending[key] ?? store.data.obj(_field)[key]) ==
        jsonEncode(value)) {
      return;
    }
    // The next picker can use the path while an unrelated snapshot is saving.
    _pending[key] = value;
    try {
      await store.change((draft) {
        // A queued write must not recreate data for a removed account.
        if (!_hasOwner(draft, session)) return;
        final all = draft.obj(_field)..remove(key);
        while (all.length >= _limit) {
          all.remove(all.keys.first);
        }
        all[key] = value;
        draft[_field] = all;
      });
    } finally {
      if (identical(_pending[key], value)) _pending.remove(key);
    }
  }
}
