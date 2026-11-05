import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'state_store.dart';

class ExternalPlayerHistory {
  ExternalPlayerHistory(this.store);
  final StateStore store;
  static const limit = 12;
  List<String> get windows => _paths(store.data);
  static List<String> _paths(Json data) => <String>{
    if (_valid(data.str('windowsExternalPlayer')))
      data.str('windowsExternalPlayer'),
    for (final value
        in (data['windowsExternalPlayers'] is List
            ? data['windowsExternalPlayers'] as List
            : const []))
      if (value is String && _valid(value)) value,
  }.take(limit).toList();
  static bool _valid(String path) =>
      path.length <= 4096 &&
      p.windows.isAbsolute(path) &&
      p.extension(path).toLowerCase() == '.exe' &&
      !RegExp(r'[\x00-\x1f]').hasMatch(path);
  Future<void> used(String path) => store.change((draft) {
    require(_valid(path), '播放器路径无效');
    final previous = _paths(draft);
    draft['windowsExternalPlayer'] = path;
    draft['windowsExternalPlayers'] = [
      path,
      ...previous.where((v) => !p.windows.equals(v, path)),
    ].take(limit).toList();
  });
}
