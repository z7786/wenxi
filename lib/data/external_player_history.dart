import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'state_store.dart';

class ExternalPlayerHistory {
  ExternalPlayerHistory(this.store);
  final StateStore store;
  static const limit = 12;
  List<String> get windows => _paths(store.data);
  List<String> get macos => _macPaths(store.data);
  static bool _validMac(String path) =>
      path.length <= 4096 &&
      p.posix.isAbsolute(path) &&
      path.toLowerCase().endsWith('.app') &&
      !RegExp(r'[\x00-\x1f]').hasMatch(path);
  static List<String> _macPaths(Json data) => <String>{
    for (final value
        in (data['macosExternalPlayers'] is List
            ? data['macosExternalPlayers'] as List
            : const []))
      if (value is String && _validMac(value)) value,
  }.take(limit).toList();
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
  Future<void> used(String path, {String platform = 'windows'}) =>
      store.change((draft) {
        if (platform == 'macos') {
          require(_validMac(path), '播放器路径无效');
          draft['macosExternalPlayers'] = [
            path,
            ..._macPaths(draft).where((value) => value != path),
          ].take(limit).toList();
          return;
        }
        require(_valid(path), '播放器路径无效');
        final previous = _paths(draft);
        draft['windowsExternalPlayer'] = path;
        draft['windowsExternalPlayers'] = [
          path,
          ...previous.where((v) => !p.windows.equals(v, path)),
        ].take(limit).toList();
      });
}
