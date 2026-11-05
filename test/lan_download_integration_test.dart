import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _LocalIo extends HttpOverrides {}

class _ObservedFiles extends LanFiles {
  _ObservedFiles() : super(android: false);
  final ranges = <(int, int?)>[];
  @override
  Stream<List<int>> read(LanLocalFile file, [int start = 0, int? end]) async* {
    ranges.add((start, end));
    yield* super.read(file, start, end);
  }
}

void main() {
  final executable = p.absolute('native/bin/asterlink_gopeed.exe');
  group(
    'LAN with the actual Windows download engine',
    () {
      late Directory root;
      late LanService sender;
      late _ObservedFiles sources;
      late StateStore store;
      late DownloadManager manager;
      late String destination;

      Future<void> openManager() async {
        final transport = DesktopGopeedTransport(executable: executable);
        final engine = GopeedEngine(
          transport,
          store,
          Vault(store),
          Directory(p.join(root.path, 'native')),
          Directory(p.join(root.path, 'cache')),
        );
        manager = DownloadManager(
          store: store,
          engine: engine,
          files: PlatformFileAccess(
            transport,
            Directory(p.join(root.path, 'default')),
          ),
          cleanups: CleanupOutbox(store, FakeHttp()),
          http: TransferHttp(),
          refreshSource: (_) async =>
              throw StateError('LAN transfers must not call a cloud connector'),
        );
        await manager.initialize();
      }

      Future<DownloadTask> finished(String id) async {
        await until(
          () => !manager.task(id)!.active && manager.activeCount == 0,
          timeout: const Duration(seconds: 40),
        );
        return manager.task(id)!;
      }

      setUp(() async {
        HttpOverrides.global = _LocalIo();
        root = await Directory.systemTemp.createTemp('aster-lan-engine-');
        root = Directory(await root.resolveSymbolicLinks());
        destination = p.join(root.path, 'received');
        sources = _ObservedFiles();
        sender = LanService(
          store: StateStore.memory(),
          files: sources,
          discoveryEnabled: false,
          requestedPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
          addresses: () async => ['127.0.0.1'],
        );
        await sender.start();
        store = StateStore.memory({
          'settings': {
            'threads': 64,
            'concurrent': 2,
            'retries': 0,
            'destination': p.join(root.path, 'default'),
          },
        });
        await openManager();
      });
      tearDown(() async {
        await manager.close();
        manager.dispose();
        await sender.close();
        await root.delete(recursive: true);
        HttpOverrides.global = null;
      });

      test(
        'Folder delivery keeps names, empty folders, hashes and the selected destination',
        () async {
          final folder = Directory(p.join(root.path, '资料'));
          await Directory(p.join(folder.path, '空目录')).create(recursive: true);
          await Directory(p.join(folder.path, '子目录')).create();
          final payload = Uint8List.fromList(
            List.generate(2 * 1024 * 1024 + 11, (i) => i % 251),
          );
          await File(
            p.join(folder.path, '子目录', '原文件.apk'),
          ).writeAsBytes(payload);
          await File(p.join(folder.path, '空文件.txt')).writeAsBytes([]);
          final shared = await sender.createShare(
            await sources.scan([folder.path], folder: true),
          );
          final manifest = await sender.readShare(
            sender.shareUrl(shared).toString(),
          );
          await sources.createDirectories(destination, manifest.directories);
          final ids = await manager.enqueueAll(
            manifest.downloads(sender.base()),
            destination: destination,
          );
          await until(
            () =>
                ids.every((id) => !manager.task(id)!.active) &&
                manager.activeCount == 0,
            timeout: const Duration(seconds: 40),
          );
          for (final id in ids) {
            final task = manager.task(id)!;
            expect(task.status, DownloadStatus.completed, reason: task.error);
            expect(task.connections, 4);
            expect(task.destination, destination);
            final saved = File(task.savedPath!);
            expect(
              await sha256
                  .bind(saved.openRead())
                  .first
                  .then((hash) => hash.toString()),
              task.spec.checksumValue,
            );
            expect(p.isWithin(destination, saved.path), isTrue);
          }
          expect(
            await File(
              p.join(destination, '资料', '子目录', '原文件.apk'),
            ).readAsBytes(),
            payload,
          );
          expect(await File(p.join(destination, '资料', '空文件.txt')).length(), 0);
          expect(
            await Directory(p.join(destination, '资料', '空目录')).exists(),
            isTrue,
          );
          expect(
            await Directory(p.join(root.path, 'default')).exists(),
            isFalse,
          );
        },
      );

      test(
        'A partial download resumes after receiver engine restart and verifies the entire file',
        () async {
          await store.put('settings', {
            'threads': 4,
            'concurrent': 1,
            'retries': 0,
            'speedLimit': 512 * 1024,
          });
          final payload = Uint8List.fromList(
            List.generate(6 * 1024 * 1024 + 3, (i) => (i * 19) % 251),
          );
          final file = File(p.join(root.path, '续传测试.bin'));
          await file.writeAsBytes(payload);
          final shared = await sender.createShare(
            await sources.scan([file.path]),
          );
          final spec = shared.manifest.downloads(sender.base()).single;
          final id = (await manager.enqueueAll([
            spec,
          ], destination: destination)).single;
          await until(
            () => manager.task(id)!.downloaded > 0 || !manager.task(id)!.active,
          );
          await manager.pause(id);
          final paused = manager.task(id)!;
          expect(paused.status, DownloadStatus.paused, reason: paused.error);
          expect(paused.downloaded, inExclusiveRange(0, payload.length));
          await manager.close();
          manager.dispose();
          sources.ranges.clear();
          await openManager();
          expect(manager.task(id)!.downloaded, paused.downloaded);
          expect(manager.task(id)!.spec.url, spec.url);
          await manager.resume(id);
          final done = await finished(id);
          expect(done.status, DownloadStatus.completed, reason: done.error);
          expect(sources.ranges.any((range) => range.$1 > 0), isTrue);
          expect(await File(done.savedPath!).readAsBytes(), payload);
        },
      );

      test(
        'A mismatching checksum never exports a corrupt received file',
        () async {
          final file = File(p.join(root.path, '校验.txt'));
          await file.writeAsString('LAN integrity check');
          final shared = await sender.createShare(
            await sources.scan([file.path]),
          );
          final original = shared.manifest.downloads(sender.base()).single;
          final spec = DownloadSpec.fromJson({
            ...original.toJson(),
            'checksumValue': '0' * 64,
          });
          final id = (await manager.enqueueAll([
            spec,
          ], destination: destination)).single;
          final failed = await finished(id);
          expect(failed.status, DownloadStatus.failed);
          expect(failed.error, contains('校验'));
          expect(failed.savedPath, isNull);
          expect(await File(p.join(destination, '校验.txt')).exists(), isFalse);
        },
      );

      test(
        'Ended shares explain how to receive again instead of a bare HTTP status',
        () async {
          final file = File(p.join(root.path, '结束.txt'));
          await file.writeAsString('ended');
          final shared = await sender.createShare(
            await sources.scan([file.path]),
          );
          final spec = shared.manifest.downloads(sender.base()).single;
          sender.stopShare(shared);
          final id = (await manager.enqueueAll([
            spec,
          ], destination: destination)).single;
          final failed = await finished(id);
          expect(failed.status, DownloadStatus.failed);
          expect(failed.error, contains('分享已结束或过期'));
        },
      );
    },
    skip: !Platform.isWindows || !File(executable).existsSync()
        ? 'Requires the packaged Windows download helper'
        : false,
  );
}
