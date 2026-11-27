import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

import 'lan_models.dart';

class _ZipRecord {
  _ZipRecord(this.name, this.size, this.offset, this.crc, this.directory);
  final Uint8List name;
  final int size, offset, crc;
  final bool directory;
}

Uint8List _zipBytes(int length, void Function(ByteData) write) {
  final value = ByteData(length);
  write(value);
  return value.buffer.asUint8List();
}

/// Stored ZIP64 with data descriptors. Files are read once, with CRC calculated
/// as the socket applies back pressure. Only the bounded central directory
/// remains in memory, so neither sender nor browser needs a whole-file buffer.
Stream<List<int>> lanBrowserZip(
  LanManifest manifest,
  Stream<List<int>> Function(LanFileEntry) read,
  void Function() checkpoint,
) async* {
  final records = <_ZipRecord>[];
  var offset = 0;
  // Extractors create parents for files. Explicit directories keep even deep
  // manifests within the existing entry limit and preserve empty folders.
  final sorted = manifest.directories.toList()..sort();
  final entries = <({String path, LanFileEntry? file})>[
    for (final directory in sorted) (path: '$directory/', file: null),
    for (final file in manifest.files) (path: file.path, file: file),
  ];
  for (final entry in entries) {
    checkpoint();
    final name = Uint8List.fromList(utf8.encode(entry.path));
    final size = entry.file?.size ?? 0, start = offset;
    final local = _zipBytes(30 + name.length + 20, (value) {
      value.setUint32(0, 0x04034b50, Endian.little);
      value.setUint16(4, 45, Endian.little);
      value.setUint16(6, 0x0808, Endian.little);
      value.setUint16(12, 0x0021, Endian.little);
      value.setUint32(18, 0xffffffff, Endian.little);
      value.setUint32(22, 0xffffffff, Endian.little);
      value.setUint16(26, name.length, Endian.little);
      value.setUint16(28, 20, Endian.little);
      value.buffer.asUint8List().setRange(30, 30 + name.length, name);
      final extra = 30 + name.length;
      value.setUint16(extra, 1, Endian.little);
      value.setUint16(extra + 2, 16, Endian.little);
      value.setUint64(extra + 4, size, Endian.little);
      value.setUint64(extra + 12, size, Endian.little);
    });
    yield local;
    offset += local.length;
    var crc = 0, transferred = 0;
    if (entry.file != null) {
      await for (final chunk in read(entry.file!)) {
        checkpoint();
        transferred += chunk.length;
        if (transferred > size) {
          throw const HttpException('Source file changed');
        }
        crc = getCrc32(chunk, crc);
        yield chunk;
        offset += chunk.length;
      }
      if (transferred != size) {
        throw const HttpException('Source file truncated');
      }
    }
    final descriptor = _zipBytes(24, (value) {
      value.setUint32(0, 0x08074b50, Endian.little);
      value.setUint32(4, crc, Endian.little);
      value.setUint64(8, size, Endian.little);
      value.setUint64(16, size, Endian.little);
    });
    yield descriptor;
    offset += descriptor.length;
    records.add(_ZipRecord(name, size, start, crc, entry.file == null));
  }
  final centralStart = offset;
  for (final record in records) {
    checkpoint();
    final central = _zipBytes(46 + record.name.length + 28, (value) {
      value.setUint32(0, 0x02014b50, Endian.little);
      value.setUint16(4, 0x032d, Endian.little);
      value.setUint16(6, 45, Endian.little);
      value.setUint16(8, 0x0808, Endian.little);
      value.setUint16(14, 0x0021, Endian.little);
      value.setUint32(16, record.crc, Endian.little);
      value.setUint32(20, 0xffffffff, Endian.little);
      value.setUint32(24, 0xffffffff, Endian.little);
      value.setUint16(28, record.name.length, Endian.little);
      value.setUint16(30, 28, Endian.little);
      value.setUint32(
        38,
        record.directory ? 0x41ed0010 : 0x81a40000,
        Endian.little,
      );
      value.setUint32(42, 0xffffffff, Endian.little);
      value.buffer.asUint8List().setRange(
        46,
        46 + record.name.length,
        record.name,
      );
      final extra = 46 + record.name.length;
      value.setUint16(extra, 1, Endian.little);
      value.setUint16(extra + 2, 24, Endian.little);
      value.setUint64(extra + 4, record.size, Endian.little);
      value.setUint64(extra + 12, record.size, Endian.little);
      value.setUint64(extra + 20, record.offset, Endian.little);
    });
    yield central;
    offset += central.length;
  }
  final centralSize = offset - centralStart;
  checkpoint();
  yield _zipBytes(98, (value) {
    value.setUint32(0, 0x06064b50, Endian.little);
    value.setUint64(4, 44, Endian.little);
    value.setUint16(12, 45, Endian.little);
    value.setUint16(14, 45, Endian.little);
    value.setUint64(24, records.length, Endian.little);
    value.setUint64(32, records.length, Endian.little);
    value.setUint64(40, centralSize, Endian.little);
    value.setUint64(48, centralStart, Endian.little);
    value.setUint32(56, 0x07064b50, Endian.little);
    value.setUint64(64, offset, Endian.little);
    value.setUint32(72, 1, Endian.little);
    value.setUint32(76, 0x06054b50, Endian.little);
    value.setUint16(84, 0xffff, Endian.little);
    value.setUint16(86, 0xffff, Endian.little);
    value.setUint32(88, 0xffffffff, Endian.little);
    value.setUint32(92, 0xffffffff, Endian.little);
  });
}
