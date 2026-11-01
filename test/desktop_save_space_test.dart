import 'dart:io';

import 'package:asterlink/download/space_budget.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'An 85 GiB payload fits a 120 GiB volume without a second copy',
    () async {
      const bytes = 91324756540;
      const volume = StorageVolume('selected', 'selected');
      const linked = StoragePlan(volume, volume, copyOnSave: false);
      const copied = StoragePlan(volume, volume);
      final budget = SpaceBudget(() async => 120 * 1024 * 1024 * 1024);
      await budget.reserveVolumes('file', linked.requirements(bytes, 0));
      budget.release('file');
      await expectLater(
        budget.reserveVolumes('file', copied.requirements(bytes, 0)),
        throwsA(
          isA<DownloadSpaceException>()
              .having((e) => e.requiredBytes, 'requiredBytes', bytes * 2)
              .having((e) => e.volume, 'volume', 'selected'),
        ),
      );
    },
  );

  test('Copying across volumes still reserves a complete destination', () {
    const plan = StoragePlan(
      StorageVolume('old', 'old'),
      StorageVolume('selected', 'selected'),
    );
    expect(plan.requirements(100, 40), {'old': 60, 'selected': 100});
    expect(plan.requirements(100, 100), {'old': 0, 'selected': 100});
  });

  group('Windows same-volume publication', () {
    late Directory root, destination;
    late File source;
    late PlatformFileAccess files;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('aster-save-space-');
      destination = await Directory(p.join(root.path, 'downloads')).create();
      source = File(
        p.join(destination.path, '.asterlink-cache', 'id', 'payload'),
      );
      await source.parent.create(recursive: true);
      await source.writeAsBytes([1, 2, 3, 4]);
      files = PlatformFileAccess(FakeNative(), destination, android: false);
    });

    tearDown(() async {
      final resolved = await root.resolveSymbolicLinks();
      expect(
        p.isWithin(await Directory.systemTemp.resolveSymbolicLinks(), resolved),
        isTrue,
      );
      expect(p.basename(resolved), startsWith('aster-save-space-'));
      await root.delete(recursive: true);
    });

    Future<String> save({void Function()? checkpoint}) => files.save(
      id: 'id',
      source: source,
      name: '下载验证.bin',
      relativePath: '',
      checkpoint: checkpoint ?? () {},
    );

    test(
      'The native volume plan and publication share the existing data',
      () async {
        final plan = await files.storagePlan(
          source.parent.path,
          destination.path,
        );
        expect(plan.copyOnSave, isFalse);
        expect(plan.cache.id, plan.target.id);
        final saved = await save();
        expect(await FileSystemEntity.identical(source.path, saved), isTrue);
        expect(await source.readAsBytes(), [1, 2, 3, 4]);
        await source.delete();
        expect(await File(saved).readAsBytes(), [1, 2, 3, 4]);
      },
    );

    test(
      'Existing user files survive collisions and repeated publication',
      () async {
        final existing = File(p.join(destination.path, '下载验证.bin'));
        await existing.writeAsBytes([9, 8, 7]);
        final saved = await save();
        expect(p.basename(saved), '下载验证 (1).bin');
        expect(await existing.readAsBytes(), [9, 8, 7]);
        final retried = await save();
        expect(retried, isNot(saved));
        expect(await FileSystemEntity.identical(source.path, retried), isTrue);
        expect(
          await destination.list().where((entry) => entry is File).length,
          3,
        );
        expect(await source.readAsBytes(), [1, 2, 3, 4]);
      },
    );

    test(
      'Cancelling after publication keeps the complete resumable payload',
      () async {
        var checks = 0;
        await expectLater(
          save(
            checkpoint: () {
              if (++checks == 3) throw StateError('cancelled');
            },
          ),
          throwsStateError,
        );
        expect(await source.readAsBytes(), [1, 2, 3, 4]);
        expect(
          await File(p.join(destination.path, '下载验证.bin')).exists(),
          isFalse,
        );
        final saved = await save();
        expect(await File(saved).readAsBytes(), [1, 2, 3, 4]);
      },
    );
  }, skip: !Platform.isWindows);
}
