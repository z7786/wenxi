import '../data/resource_pool_preview.dart';
import 'models.dart';

/// One in-memory directory checkpoint for returning from the transfer tab.
/// Session credentials are never written to navigation history on disk.
class BrowserReturnTarget {
  BrowserReturnTarget({
    required this.session,
    required List<CloudFile> items,
    required List<(String, String)> trail,
    this.scrollOffset = 0,
    this.searchText = '',
    this.poolPreview,
    this.cursor,
  }) : items = List.unmodifiable(items),
       trail = List.unmodifiable(trail);
  final BrowseSession session;
  final List<CloudFile> items;
  final List<(String, String)> trail;
  final double scrollOffset;
  final String searchText;
  final ResourcePoolPreview? poolPreview;
  final String? cursor;
  String get directory => trail.isEmpty ? '全部文件' : trail.last.$2;
}
