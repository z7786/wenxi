import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/platform/apple_storage.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/windows_storage.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/apple-storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'directory moves use the longest prefix, follow upgrades and keep boundary paths',
    () {
      const paths = {
        '/old': '/middle',
        '/middle': '/current',
        '/old/external': '/provider',
      };
      expect(remapApplePath('/old/file', paths), '/current/file');
      expect(remapApplePath('/old/external/file', paths), '/provider/file');
      expect(remapApplePath('/older/file', paths), '/older/file');
      expect(
        remapApplePath('https://test.invalid/old/file', paths),
        'https://test.invalid/old/file',
      );
      expect(remapApplePath('/a/file', {'/a': '/b', '/b': '/a'}), '/a/file');
      expect(remapApplePath('/a/file', {'/a': '/a/moved'}), '/a/moved/file');
    },
  );

  test('storage recovery preserves accounts, task state and source URLs', () async {
    const before =
        '/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111';
    const after =
        '/var/mobile/Containers/Data/Application/22222222-2222-2222-2222-222222222222';
    final store = StateStore.memory({
      'credentials': {
        'Baidu': {'primary': '$before/credential-value'},
      },
      'settings': {
        'destination': '$before/Documents/Downloads',
        'connections': 16,
      },
      'lanDestination': '/provider-before/Shared',
      'downloadCacheRoots': {
        'pending': '$before/Documents/Downloads/.asterlink-cache',
      },
      'tasks': [
        {
          'id': 'pending',
          'destination': '$before/Documents/Downloads',
          'savedPath': '$before/Documents/Downloads/video.mp4',
          'status': 'paused',
          'downloaded': 9007199254740993,
          'spec': {
            'url': 'https://example.invalid/video',
            'headers': {'Cookie': 'fixture-session'},
          },
        },
        {
          'id': 'external',
          'destination': '/provider-before/Shared',
          'savedPath': '/provider-before/Shared/one.txt',
        },
      ],
    });
    addTearDown(store.dispose);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'restoreStorage');
      // No home marker from the old build: infer it only from storage fields.
      return {
        'home': after,
        'paths': {'/provider-before': '/provider-after'},
      };
    });
    await restoreAppleStorage(store, ios: true, channel: channel);
    expect(
      store.data.obj('settings').str('destination'),
      '$after/Documents/Downloads',
    );
    expect(store.data.obj('settings').integer('connections'), 16);
    expect(store.data.str('lanDestination'), '/provider-after/Shared');
    expect(
      store.data.obj('downloadCacheRoots').str('pending'),
      '$after/Documents/Downloads/.asterlink-cache',
    );
    final task = store.data.list('tasks').first;
    expect(task.str('savedPath'), '$after/Documents/Downloads/video.mp4');
    expect(task.integer('downloaded'), 9007199254740993);
    expect(task.str('status'), 'paused');
    expect(task.obj('spec'), {
      'url': 'https://example.invalid/video',
      'headers': {'Cookie': 'fixture-session'},
    });
    expect(
      store.data.obj('credentials').obj('Baidu').str('primary'),
      '$before/credential-value',
    );
    expect(
      store.data.list('tasks').last.str('savedPath'),
      '/provider-after/Shared/one.txt',
    );
    final snapshot = encoded(store.data);
    await restoreAppleStorage(store, ios: true, channel: channel);
    expect(encoded(store.data), snapshot);
  });

  test('container inference excludes arbitrary folders and provider suffixes', () {
    const home =
        '/var/mobile/Containers/Data/Application/22222222-2222-2222-2222-222222222222';
    const old =
        '/private/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111';
    expect(appleStorageMappings({'home': home}, ['$old/Documents/file']), {
      old: home,
    });
    expect(
      appleStorageMappings(
        {'home': home},
        [
          '/data/file',
          '$old-malicious/Documents/file',
          'https://example.invalid/$old/Documents/file',
        ],
      ),
      isEmpty,
    );
  });

  group(
    'Apple file publication with real files',
    () {
      late Directory root, destination;
      late File source;
      late PlatformFileAccess files;
      var links = true, checks = 0;
      setUp(() async {
        links = true;
        checks = 0;
        root = await Directory.systemTemp.createTemp('aster-apple-storage-');
        destination = await Directory(p.join(root.path, 'downloads')).create();
        source = File(
          p.join(destination.path, '.asterlink-cache', 'one', 'payload'),
        );
        await source.parent.create(recursive: true);
        await source.writeAsBytes([1, 2, 3, 4]);
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'storageVolume') {
            return {'id': 'test-volume', 'hardLinks': true};
          }
          expect(call.method, 'createHardLink');
          if (!links) return false;
          final sourcePath = call.arguments['source'] as String;
          final targetPath = call.arguments['target'] as String;
          try {
            if (Platform.isWindows) {
              WindowsStorage.createHardLink(sourcePath, targetPath);
              return true;
            }
            // Keep these real-file regressions active on Apple CI runners too.
            final result = await Process.run('/bin/ln', [
              sourcePath,
              targetPath,
            ]);
            return result.exitCode == 0;
          } on FileSystemException {
            return false;
          }
        });
        files = PlatformFileAccess(
          FakeNative(),
          destination,
          android: false,
          appleStorage: const AppleStorage(enabled: true, channel: channel),
        );
      });
      tearDown(() async {
        final path = await root.resolveSymbolicLinks();
        expect(
          p.isWithin(await Directory.systemTemp.resolveSymbolicLinks(), path),
          isTrue,
        );
        expect(p.basename(path), startsWith('aster-apple-storage-'));
        await root.delete(recursive: true);
      });
      Future<String> save({bool cancel = false}) => files.save(
        id: 'one',
        source: source,
        name: 'file.bin',
        relativePath: '',
        checkpoint: () {
          if (cancel && ++checks == 3) throw StateError('cancel');
        },
      );
      test(
        'native same-volume links keep the source and existing user files',
        () async {
          final user = File(p.join(destination.path, 'file.bin'));
          await user.writeAsBytes([9]);
          expect(
            (await files.storagePlan(
              source.parent.path,
              destination.path,
            )).copyOnSave,
            isFalse,
          );
          final path = await save();
          expect(p.basename(path), 'file (1).bin');
          expect(await FileSystemEntity.identical(source.path, path), isTrue);
          expect(await user.readAsBytes(), [9]);
          await source.delete();
          expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
        },
      );
      test(
        'a refused link falls back to copying without losing the payload',
        () async {
          links = false;
          final path = await save();
          expect(await FileSystemEntity.identical(source.path, path), isFalse);
          expect(await source.readAsBytes(), [1, 2, 3, 4]);
          expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
        },
      );
      test(
        'cancelling after creating the link keeps a resumable source',
        () async {
          await expectLater(save(cancel: true), throwsStateError);
          expect(await source.readAsBytes(), [1, 2, 3, 4]);
          expect(
            await File(p.join(destination.path, 'file.bin')).exists(),
            isFalse,
          );
          expect(await File(await save()).readAsBytes(), [1, 2, 3, 4]);
        },
      );
    },
    skip: !(Platform.isWindows || Platform.isMacOS || Platform.isLinux),
  );
}
