import '../core/json.dart';
import 'file_types.dart';

const torrentDataPrefix = 'data:application/x-bittorrent;base64,';
const maxTorrentBytes = 4 * 1024 * 1024;
const maxTorrentFiles = 10000;

class TorrentFile {
  const TorrentFile(this.index, this.path, this.size);
  final int index, size;
  final String path;
  bool get playable =>
      size > 0 && {FileKind.video, FileKind.audio}.contains(fileKind(name));
  String get name => path.split('/').last;
  String get directory =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
  factory TorrentFile.fromJson(Json j) =>
      TorrentFile(j.integer('index'), j.str('path'), j.integer('size'));
}

class TorrentInfo {
  const TorrentInfo(
    this.hash,
    this.name,
    this.data,
    this.files, {
    this.pieceLength = 4 * 1024 * 1024,
  });
  final String hash, name, data;
  final List<TorrentFile> files;
  final int pieceLength;
  int get size => files.fold(0, (sum, file) => sum + file.size);
  String get magnet => 'magnet:?xt=urn:btih:$hash';
  factory TorrentInfo.fromJson(Json j) {
    final files = j.list('files').map(TorrentFile.fromJson).toList();
    require(
      RegExp(r'^[0-9a-f]{40}$').hasMatch(j.str('hash')) &&
          j.str('data').startsWith(torrentDataPrefix) &&
          files.isNotEmpty &&
          files.length <= maxTorrentFiles &&
          j.integer('pieceLength') > 0 &&
          j.integer('pieceLength') <= 64 * 1024 * 1024 &&
          j.str('data').length <= maxTorrentBytes * 4 ~/ 3 + 100,
      '种子信息无效',
    );
    require(
      files.asMap().entries.every(
        (entry) =>
            entry.key == entry.value.index &&
            entry.value.size >= 0 &&
            entry.value.path.isNotEmpty,
      ),
      '种子文件列表无效',
    );
    return TorrentInfo(
      j.str('hash'),
      j.str('name'),
      j.str('data'),
      files,
      pieceLength: j.integer('pieceLength'),
    );
  }
}
