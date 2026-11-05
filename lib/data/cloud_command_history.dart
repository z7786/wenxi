import '../core/json.dart';
import '../domain/models.dart';
import 'cloud_command_resolver.dart';
import 'state_store.dart';

class CloudCommandHistoryEntry {
  const CloudCommandHistoryEntry({
    required this.id,
    required this.platform,
    required this.text,
    required this.link,
    required this.title,
    required this.createdAt,
    this.itemCount,
  });

  final String id, text, title;
  final CloudPlatform platform;
  final ParsedLink link;
  final int createdAt;
  final int? itemCount;

  Json toJson() => {
    'id': id,
    'platform': platform.key,
    'text': text,
    'link': link.toJson(),
    'title': title,
    'createdAt': createdAt,
    if (itemCount != null) 'itemCount': itemCount,
  };
}

/// Original command text stays in the app's private local store. Whitespace and
/// Unicode must survive unchanged because command signatures use the raw text.
class CloudCommandHistory {
  const CloudCommandHistory(this.store);
  final StateStore store;
  static const limit = 300;

  static List<CloudCommandHistoryEntry> _read(Json data) => [
    for (final item in data.list('commandHistory'))
      if (CloudPlatform.fromKey(item.str('platform')) case final platform?)
        if (CloudCommandResolver.platforms.contains(platform) &&
            item.str('id').isNotEmpty &&
            item.str('text').trim().isNotEmpty &&
            item.str('text').length <= CloudCommandResolver.maximumLength &&
            item['link'] is Map)
          CloudCommandHistoryEntry(
            id: item.str('id'),
            platform: platform,
            text: item.str('text'),
            link: ParsedLink.fromJson(item.obj('link')),
            title: item.str('title'),
            createdAt: item.integer('createdAt'),
            itemCount: item['itemCount'] == null
                ? null
                : item.integer('itemCount'),
          ),
  ].take(limit).toList(growable: false);

  List<CloudCommandHistoryEntry> get all => _read(store.data);

  /// Commit alongside ordinary parse history under the same cancellation guard.
  static void record(
    Json draft,
    ParsedLink link,
    String text, {
    required int createdAt,
    String? title,
    int? itemCount,
  }) {
    final platform = link.platform;
    if (platform == null ||
        link.kind != LinkKind.cloudShare ||
        !CloudCommandResolver.platforms.contains(platform) ||
        text.trim().isEmpty ||
        text.length > CloudCommandResolver.maximumLength) {
      return;
    }
    final previous = _read(draft);
    bool same(CloudCommandHistoryEntry item) =>
        item.platform == platform && item.text == text;
    final entry = CloudCommandHistoryEntry(
      id: previous.where(same).firstOrNull?.id ?? newId(),
      platform: platform,
      text: text,
      link: link,
      title: title ?? '',
      createdAt: createdAt,
      itemCount: itemCount,
    );
    draft['commandHistory'] = [
      entry.toJson(),
      ...previous
          .where((item) => !same(item))
          .take(limit - 1)
          .map((e) => e.toJson()),
    ];
  }

  Future<void> remove(String id) => store.change((draft) {
    draft['commandHistory'] = draft
        .list('commandHistory')
        .where((item) => item.str('id') != id)
        .toList();
  });

  Future<void> clear() => store.put('commandHistory', []);
}
