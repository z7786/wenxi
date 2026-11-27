import '../domain/torrent.dart';

class TorrentFileNode {
  TorrentFileNode(this.path, {this.file});

  final String path;
  final TorrentFile? file;
  final folders = <String, TorrentFileNode>{};
  final children = <TorrentFileNode>[];
  final indices = <int>[];
  int size = 0;

  String get name => path.split('/').last;
  bool get directory => file == null;
}

class TorrentFileTree {
  TorrentFileTree(List<TorrentFile> files) {
    for (final file in files) {
      var parent = root;
      parent.indices.add(file.index);
      parent.size += file.size;
      final parts = file.path.split('/');
      var path = '';
      for (final part in parts.take(parts.length - 1)) {
        path = path.isEmpty ? part : '$path/$part';
        final folder = parent.folders.putIfAbsent(part, () {
          final node = TorrentFileNode(path);
          parent.children.add(node);
          return node;
        });
        folder.indices.add(file.index);
        folder.size += file.size;
        parent = folder;
      }
      parent.children.add(TorrentFileNode(file.path, file: file));
    }
    void order(TorrentFileNode node) {
      node.children.sort((a, b) {
        if (a.directory != b.directory) return a.directory ? -1 : 1;
        return a.directory
            ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
            : a.file!.index.compareTo(b.file!.index);
      });
      for (final folder in node.folders.values) {
        order(folder);
      }
    }

    order(root);
  }

  final root = TorrentFileNode('');
}
