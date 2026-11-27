import 'dart:io';

import 'package:asterlink/platform/storage_path.dart';
import 'package:asterlink/platform/completed_file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'storage_path_support.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-storage-path-');
    root = Directory(await root.resolveSymbolicLinks());
  });
  tearDown(() async {
    final path = await root.resolveSymbolicLinks();
    expect(
      p.isWithin(await Directory.systemTemp.resolveSymbolicLinks(), path),
      isTrue,
    );
    expect(p.basename(path), startsWith('aster-storage-path-'));
    await root.delete(recursive: true);
  });

  for (final code in [1, 50]) {
    test(
      'unsupported Windows query $code accepts ordinary existing paths',
      () async {
        final nested = await Directory(p.join(root.path, 'nested')).create();
        final file = await File(
          p.join(nested.path, 'payload'),
        ).writeAsBytes([1, 2]);
        final paths = UnsupportedFinalPaths(root.path, errorCode: code);
        await paths.run(() async {
          final created = await Directory(
            p.join(root.path, 'created', 'task'),
          ).create(recursive: true);
          expect(
            await FileSystemEntity.type(created.path, followLinks: false),
            FileSystemEntityType.directory,
          );
          expect(
            await resolveStoragePath(Directory(nested.path)),
            p.normalize(nested.path),
          );
          expect(
            await resolveStoragePath(File(file.path)),
            p.normalize(file.path),
          );
        });
        expect(paths.attempts, hasLength(2));
      },
      skip: !Platform.isWindows,
    );
  }

  for (final code in [2, 3, 5, 32]) {
    test('real path errors $code are never swallowed', () async {
      final paths = UnsupportedFinalPaths(root.path, errorCode: code);
      await expectLater(
        paths.run(() => resolveStoragePath(Directory(root.path))),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.osError?.errorCode,
            'code',
            code,
          ),
        ),
      );
    });
  }

  test('missing objects do not become valid fallback paths', () async {
    final paths = UnsupportedFinalPaths(root.path);
    await expectLater(
      paths.run(() => resolveStoragePath(File(p.join(root.path, 'missing')))),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('fallback refuses a symbolic link in an ancestor', () async {
    final outside = await Directory(p.join(root.path, 'outside')).create();
    final source = await File(
      p.join(outside.path, 'payload'),
    ).writeAsBytes([7]);
    final link = Link(p.join(root.path, 'redirect'));
    try {
      await link.create(outside.path);
    } on FileSystemException {
      markTestSkipped('symlink creation unavailable');
      return;
    }
    try {
      final paths = UnsupportedFinalPaths(root.path);
      await expectLater(
        paths.run(() => resolveStoragePath(File(p.join(link.path, 'payload')))),
        throwsA(isA<FileSystemException>()),
      );
      expect(await source.readAsBytes(), [7]);
    } finally {
      await link.delete();
    }
  }, skip: !Platform.isWindows);

  test(
    'supported symbolic link resolution still returns its actual target',
    () async {
      final target = await Directory(p.join(root.path, 'actual')).create();
      final link = Link(p.join(root.path, 'link'));
      try {
        await link.create(target.path);
      } on FileSystemException {
        markTestSkipped('symlink creation unavailable');
        return;
      }
      try {
        expect(
          await resolveStoragePath(Directory(link.path)),
          await target.resolveSymbolicLinks(),
        );
      } finally {
        await link.delete();
      }
    },
  );

  test(
    'completed file copy on a virtual disk keeps source and name collisions',
    () async {
      final destination = await Directory(
        p.join(root.path, 'downloads'),
      ).create();
      final source = await File(
        p.join(root.path, 'payload.bin'),
      ).writeAsBytes([1, 2]);
      final existing = await File(
        p.join(destination.path, 'payload.bin'),
      ).writeAsBytes([9]);
      final paths = UnsupportedFinalPaths(root.path);
      final saved = await paths.run(
        () => CompletedFileTransfer.publish(
          File(source.path),
          destination.path,
          move: false,
          checkpoint: () {},
        ),
      );
      expect(p.basename(saved.path), 'payload (1).bin');
      expect(await saved.readAsBytes(), [1, 2]);
      expect(await source.readAsBytes(), [1, 2]);
      expect(await existing.readAsBytes(), [9]);
    },
    skip: !Platform.isWindows,
  );
}
