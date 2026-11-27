import 'dart:collection';
import '../domain/downloads.dart';

class DownloadTaskIndex extends MapBase<String, DownloadTask> {
  final _entries = <String, DownloadTask>{};
  List<String>? _orderedIds;

  @override
  DownloadTask? operator [](Object? key) => _entries[key];

  @override
  void operator []=(String key, DownloadTask value) {
    if (_entries[key]?.createdAt != value.createdAt) _orderedIds = null;
    _entries[key] = value;
  }

  @override
  Iterable<String> get keys => _entries.keys;

  @override
  Iterable<DownloadTask> get values => _entries.values;

  @override
  int get length => _entries.length;

  @override
  bool containsKey(Object? key) => _entries.containsKey(key);

  @override
  DownloadTask? remove(Object? key) {
    final removed = _entries.remove(key);
    if (removed != null) _orderedIds = null;
    return removed;
  }

  @override
  void clear() {
    _entries.clear();
    _orderedIds = null;
  }

  List<DownloadTask> get ordered {
    final ids = _orderedIds ??=
        (_entries.values.toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
            .map((task) => task.id)
            .toList(growable: false);
    // Return a fresh snapshot containing the latest progress. Callers can
    // filter or sort it without changing the manager's cached order.
    return [for (final id in ids) _entries[id]!];
  }
}
