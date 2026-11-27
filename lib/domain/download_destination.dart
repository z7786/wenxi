import '../core/json.dart';

/// A confirmed choice. A null path explicitly selects the system directory;
/// an absent choice leaves the caller's default intact.
class DownloadDestinationSelection {
  const DownloadDestinationSelection(this.path, {this.makeDefault = false});
  final String? path;
  final bool makeDefault;

  static List<String> recent(Json data) =>
      (data['recentDownloadDestinations'] is List
              ? data['recentDownloadDestinations'] as List
              : const [])
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toSet()
          .take(5)
          .toList();

  void remember(Json draft) {
    if (path case final value?) {
      draft['recentDownloadDestinations'] = <String>{
        value,
        ...recent(draft),
      }.take(5).toList();
    }
  }
}
