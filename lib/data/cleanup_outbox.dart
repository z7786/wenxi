import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/json.dart';
import '../core/operation_progress.dart';
import '../domain/models.dart';
import 'http.dart';
import 'state_store.dart';

String cleanupKey(DownloadCleanup value) =>
    sha256.convert(utf8.encode(jsonEncode(value.toJson()))).toString();

class CleanupOutbox {
  CleanupOutbox(this.store, this.http);
  final StateStore store;
  final JsonHttp http;
  Future<void> Function(Json action)? executeAction;
  final _gate = AsyncGate();
  final progress = OperationProgress();
  final _leases = <String, int>{};
  int get pendingCount => store.data.obj('cleanups').length;
  Future<void> stage(DownloadCleanup cleanup, {String? accountId}) =>
      store.change((draft) {
        final key = cleanupKey(cleanup);
        draft['cleanups'] = {
          ...draft.obj('cleanups'),
          key: {
            'payload': cleanup.toJson(),
            'accountId': ?accountId,
            'ready': false,
            'attempts': 0,
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          },
        };
      });
  void retain(DownloadCleanup? cleanup) {
    if (cleanup == null) return;
    final key = cleanupKey(cleanup);
    _leases[key] = (_leases[key] ?? 0) + 1;
  }

  Future<void> release(DownloadCleanup? cleanup) async {
    if (cleanup == null) return;
    final key = cleanupKey(cleanup), count = (_leases[key] ?? 1) - 1;
    if (count <= 0) {
      _leases.remove(key);
    } else {
      _leases[key] = count;
    }
    await reconcile();
  }

  bool _used(Json draft, String key) =>
      _leases.containsKey(key) ||
      draft.list('tasks').any((t) {
        final c = t.obj('spec')['cleanup'];
        return !{'completed', 'cancelled'}.contains(t.str('status')) &&
            c is Map &&
            cleanupKey(DownloadCleanup.fromJson(asJson(c))) == key;
      });
  Set<String> _usedKeys(Json draft) => {
    ..._leases.keys,
    for (final task in draft.list('tasks'))
      if (!{'completed', 'cancelled'}.contains(task.str('status')) &&
          task.obj('spec')['cleanup'] is Map)
        cleanupKey(DownloadCleanup.fromJson(task.obj('spec').obj('cleanup'))),
  };

  bool _needsReconcile(Json draft, {required bool recoverOrphans}) {
    final raw = draft['cleanups'];
    if (raw != null && raw is! Map) return true;
    if (!recoverOrphans) return false;
    final candidates = draft
        .obj('cleanups')
        .entries
        .where((entry) => !asJson(entry.value).boolean('ready'));
    if (candidates.isEmpty) return false;
    final used = _usedKeys(draft);
    return candidates.any((entry) => !used.contains(entry.key));
  }

  Future<void> reconcile({bool recoverOrphans = false}) {
    if (!_needsReconcile(store.data, recoverOrphans: recoverOrphans)) {
      return Future.value();
    }
    return store.change(
      (draft) => reconcileInDraft(draft, recoverOrphans: recoverOrphans),
    );
  }

  /// Startup queue repair can mark orphans in the same atomic snapshot.
  void reconcileInDraft(Json draft, {bool recoverOrphans = false}) {
    final entries = draft.obj('cleanups');
    if (draft['cleanups'] != null && draft['cleanups'] is! Map) {
      draft['cleanups'] = entries;
    }
    if (entries.isEmpty || !recoverOrphans) return;
    final used = _usedKeys(draft);
    for (final e in entries.entries.toList()) {
      final item = asJson(e.value);
      // Leases protect previews and the gap between resolution and queue insertion.
      if (!item.boolean('ready') && !used.contains(e.key)) {
        entries[e.key] = {...item, 'ready': true};
      }
    }
    draft['cleanups'] = entries;
  }

  Future<void> ready(DownloadCleanup? cleanup) async {
    if (cleanup == null) return;
    final key = cleanupKey(cleanup);
    await store.change((draft) {
      final entries = draft.obj('cleanups');
      if (entries[key] != null && !_used(draft, key)) {
        entries[key] = {...asJson(entries[key]), 'ready': true};
      }
      draft['cleanups'] = entries;
    });
  }

  /// Mark cleanup in the same transaction that removes its owning records.
  /// Other downloads and preview leases still protect shared resources.
  void readyInDraft(Json draft, Iterable<DownloadCleanup?> cleanups) {
    final entries = draft.obj('cleanups');
    for (final cleanup in cleanups) {
      if (cleanup == null) continue;
      final key = cleanupKey(cleanup);
      if (entries[key] != null && !_used(draft, key)) {
        entries[key] = {...asJson(entries[key]), 'ready': true};
      }
    }
    draft['cleanups'] = entries;
  }

  Future<void> drain() => _gate.run(
    () => progress.run(() async {
      for (final entry in store.data.obj('cleanups').entries.toList()) {
        final item = asJson(entry.value);
        if (!item.boolean('ready') || _used(store.data, entry.key)) continue;
        try {
          await OperationProgress.step(OperationStage.cleanup, () async {
            final cleanup = DownloadCleanup.fromJson(item.obj('payload'));
            if (cleanup.action != null) {
              require(executeAction != null, '云端清理尚未准备好');
              await executeAction!({
                ...cleanup.action!,
                if (item.containsKey('accountId'))
                  'accountId': item.str('accountId'),
              });
            } else {
              final result = await http.request(
                cleanup.method,
                cleanup.url,
                body: cleanup.body,
                headers: cleanup.headers,
                contentType:
                    cleanup.headers['Content-Type'] ?? 'application/json',
              );
              require(result.successful, '云端清理失败');
              if (result.body.trimLeft().startsWith('{')) {
                final j = result.json;
                require(
                  (!j.containsKey('errno') || j.integer('errno') == 0) &&
                      (!j.containsKey('status') ||
                          j.integer('status') >= 200 &&
                              j.integer('status') < 300) &&
                      (!j.containsKey('code') ||
                          {'0', '0000', 'OK', '200'}.contains(j.str('code'))) &&
                      (!j.containsKey('success') || j.boolean('success')) &&
                      j.str('error').isEmpty,
                  '云端清理未成功',
                );
              }
            }
            await store.change((draft) {
              if (!_used(draft, entry.key)) {
                draft['cleanups'] = draft.obj('cleanups')..remove(entry.key);
              }
            });
          });
        } catch (_) {
          await store.change((draft) {
            final entries = draft.obj('cleanups'),
                current = asJson(entries[entry.key]);
            if (current.isNotEmpty) {
              entries[entry.key] = {
                ...current,
                'attempts': current.integer('attempts') + 1,
                'error': '云端清理失败，稍后重试',
              };
            }
            draft['cleanups'] = entries;
          });
        }
      }
    }),
  );
}
