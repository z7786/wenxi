import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/completed_file_transfer.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, destination;
  late File source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('wenxi-file-transfer-');
    destination = await Directory(p.join(root.path, 'target')).create();
    source = await File(
      p.join(root.path, 'movie.mp4'),
    ).writeAsBytes(List.generate(256 * 1024, (i) => i % 251));
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'Copy uses a new collision-free name and preserves original bytes',
    () async {
      await File(p.join(destination.path, 'movie.mp4')).writeAsString('keep');
      final output = await CompletedFileTransfer.publish(
        source,
        destination.path,
        move: false,
        checkpoint: () {},
      );
      expect(p.basename(output.path), 'movie (1).mp4');
      expect(await output.readAsBytes(), await source.readAsBytes());
      expect(
        await File(p.join(destination.path, 'movie.mp4')).readAsString(),
        'keep',
      );
    },
  );

  test(
    'Cancelling a partially copied file removes only the new output',
    () async {
      var cancelled = false;
      await expectLater(
        CompletedFileTransfer.publish(
          source,
          destination.path,
          move: false,
          checkpoint: () {
            if (cancelled) throw const AppException('已取消');
          },
          onProgress: (_, _) => cancelled = true,
        ),
        throwsA(isA<AppException>()),
      );
      expect(await source.length(), 256 * 1024);
      expect(await destination.list().toList(), isEmpty);
    },
  );

  test('Directories occupying a file name are never replaced', () async {
    await Directory(p.join(destination.path, 'movie.mp4')).create();
    final output = await CompletedFileTransfer.publish(
      source,
      destination.path,
      move: false,
      checkpoint: () {},
    );
    expect(p.basename(output.path), 'movie (1).mp4');
    expect(
      await Directory(p.join(destination.path, 'movie.mp4')).exists(),
      isTrue,
    );
  });

  Future<AppServices> managerFixture() async {
    final task = DownloadTask(
      id: 'complete',
      spec: const DownloadSpec(
        url: 'https://example.invalid/movie',
        fileName: 'movie.mp4',
      ),
      createdAt: 1,
      status: DownloadStatus.completed,
      savedPath: source.path,
    );
    final services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'tasks': [task.toJson()],
      }),
      dataDirectory: root,
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      transport: FakeNative(),
      files: FakeFiles(destination),
      http: FakeHttp(),
      platformFeatures: false,
    );
    await services.downloads.initialize();
    return services;
  }

  test(
    'Batch move commits the new path and allows later deletion of that file',
    () async {
      final services = await managerFixture();
      try {
        await File(p.join(destination.path, 'movie.mp4')).writeAsString('keep');
        final expected = await source.readAsBytes();
        final result = await services.downloads.transferCompletedFiles(
          ['complete', 'missing'],
          destination.path,
          move: true,
        );
        expect(result.succeeded, ['complete']);
        expect(result.skipped, ['missing']);
        expect(result.failed, isEmpty);
        final task = services.downloads.task('complete')!;
        expect(p.basename(task.savedPath!), 'movie (1).mp4');
        expect(await source.exists(), isFalse);
        expect(await File(task.savedPath!).readAsBytes(), expected);
        expect(
          DownloadTask.fromJson(
            services.store.data.list('tasks').single,
          ).savedPath,
          task.savedPath,
        );
        await services.downloads.delete('complete', deleteFile: true);
        expect(await File(task.savedPath!).exists(), isFalse);
        expect(
          await File(p.join(destination.path, 'movie.mp4')).readAsString(),
          'keep',
        );
      } finally {
        await services.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'Batch copy keeps original records and reports unavailable files individually',
    () async {
      final services = await managerFixture();
      try {
        final first = await services.downloads.transferCompletedFiles(
          ['complete'],
          destination.path,
          move: false,
        );
        expect(first.succeeded, ['complete']);
        expect(services.downloads.task('complete')!.savedPath, source.path);
        await source.delete();
        final second = await services.downloads.transferCompletedFiles(
          ['complete'],
          destination.path,
          move: true,
        );
        expect(second.failed.keys, ['complete']);
        expect(services.downloads.task('complete')!.savedPath, source.path);
        expect(
          await File(p.join(destination.path, 'movie.mp4')).exists(),
          isTrue,
        );
      } finally {
        await services.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'A cancelled batch leaves its original file and record intact',
    () async {
      final services = await managerFixture();
      final scope = RequestScope()..cancel();
      try {
        final result = await scope.run(
          () => services.downloads.transferCompletedFiles(
            ['complete'],
            destination.path,
            move: true,
          ),
        );
        expect(result.cancelled, isTrue);
        expect(await source.exists(), isTrue);
        expect(services.downloads.task('complete')!.savedPath, source.path);
        expect(await destination.list().toList(), isEmpty);
      } finally {
        await services.close();
      }
    },
    skip: !Platform.isWindows,
  );
}
