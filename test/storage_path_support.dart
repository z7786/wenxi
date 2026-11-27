import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Real file I/O with the unsupported final-path query reported by ImDisk.
/// Overrides are scoped to one test zone and never affect its cleanup.
class UnsupportedFinalPaths {
  UnsupportedFinalPaths(this.root, {this.errorCode = 1});
  final String root;
  final int errorCode;
  final attempts = <String>[];
  late IOOverrides _real;

  Future<T> run<T>(Future<T> Function() action) {
    _real = IOOverrides.current ?? _RealFileIo();
    final parent = Zone.current;
    return IOOverrides.runZoned(
      action,
      createDirectory: (path) => _contains(path)
          ? _Directory(_real.createDirectory(path), this)
          : _real.createDirectory(path),
      createFile: (path) => _contains(path)
          ? _File(_real.createFile(path), this)
          : _real.createFile(path),
      // Delegate type queries in the original zone too. Dart's default
      // IOOverrides type query differs from the unoverridden Windows path.
      fseGetType: (path, followLinks) => parent.run(
        () => FileSystemEntity.type(path, followLinks: followLinks),
      ),
      fseGetTypeSync: (path, followLinks) => parent.run(
        () => FileSystemEntity.typeSync(path, followLinks: followLinks),
      ),
    );
  }

  bool _contains(String path) {
    final absolute = p.normalize(p.absolute(path));
    return p.equals(root, absolute) || p.isWithin(root, absolute);
  }

  Future<String> resolve(FileSystemEntity entity) async {
    final path = p.normalize(p.absolute(entity.path));
    if (_contains(path)) {
      attempts.add(path);
      throw FileSystemException(
        'Cannot resolve symbolic links',
        path,
        OSError('Unsupported final-path query', errorCode),
      );
    }
    return entity.resolveSymbolicLinks();
  }
}

final class _RealFileIo extends IOOverrides {}

class _Directory implements Directory {
  _Directory(this.real, this.fixture);
  final Directory real;
  final UnsupportedFinalPaths fixture;
  @override
  String get path => real.path;
  @override
  Directory get absolute => _Directory(real.absolute, fixture);
  @override
  Directory get parent => _Directory(real.parent, fixture);
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<Directory> create({bool recursive = false}) async =>
      _Directory(await real.create(recursive: recursive), fixture);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      real.delete(recursive: recursive);
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => real.list(recursive: recursive, followLinks: followLinks);
  @override
  Future<String> resolveSymbolicLinks() => fixture.resolve(real);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _File implements File {
  _File(this.real, this.fixture);
  final File real;
  final UnsupportedFinalPaths fixture;
  @override
  String get path => real.path;
  @override
  Directory get parent => _Directory(real.parent, fixture);
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<int> length() => real.length();
  @override
  Future<Uint8List> readAsBytes() => real.readAsBytes();
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      real.openRead(start, end);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      real.open(mode: mode);
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async =>
      _File(
        await real.create(recursive: recursive, exclusive: exclusive),
        fixture,
      );
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async =>
      _File(await real.writeAsBytes(bytes, mode: mode, flush: flush), fixture);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      real.delete(recursive: recursive);
  @override
  Future<String> resolveSymbolicLinks() => fixture.resolve(real);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
