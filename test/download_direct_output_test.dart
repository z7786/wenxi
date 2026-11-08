import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/android_download_file.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

const _destination = 'content://fixtures/tree/chosen-downloads';
const _otherDestination = 'content://fixtures/tree/other-downloads';
const _identity = RemoteIdentity(4, '"direct-output-fixture"', null);
const _content = [1, 2, 3, 4];
const _spec = DownloadSpec(
  url: 'https://example.invalid/direct.bin',
  fileName: '直接下载.bin',
  relativePath: '文件夹/子目录',
  expectedSize: 4,
);

class _ProbeHttp extends TransferHttp {
  int probes = 0;

  @override
  Future<Probe> probe(String url, Map<String, String> headers) async {
    probes++;
    return const Probe(_identity, false, rangeSupported: true);
  }
}

class _HlsHttp extends _ProbeHttp {
  bool failSecond = false;
  final requestedParts = <String>[];

  @override
  Future<Probe> probe(String url, Map<String, String> headers) async {
    probes++;
    return const Probe(RemoteIdentity(0, null, null), true);
  }

  @override
  Future<({String text, String url})> textResponse(
    String url,
    Map<String, String> headers, {
    int limit = 2 * 1024 * 1024,
  }) async => (
    text:
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
        '#EXTINF:4,\nfirst.ts\n#EXTINF:4,\nsecond.ts\n#EXT-X-ENDLIST\n',
    url: url,
  );

  @override
  Future<Response<ResponseBody>> stream(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
  }) async {
    final name = Uri.parse(url).pathSegments.last;
    requestedParts.add(name);
    if (name == 'second.ts' && failSecond) {
      throw const AppException('视频分片暂不可用');
    }
    return Response<ResponseBody>(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      data: ResponseBody.fromBytes(
        name == 'first.ts' ? _content.sublist(0, 2) : _content.sublist(2),
        200,
      ),
    );
  }
}

class _DirectNative extends FakeNative {
  bool directOutputSupported = true,
      seedAfterDone = false,
      resumeLegacyCache = false;
  final outputs = <String, File>{};
  final grantedFiles = <String, File>{};
  final outputLocators = <String, String>{};
  final torrents = <String>{};
  final beginLengths = <int>[];
  Completer<void>? holdRemoval;
  final removalEntered = Completer<void>();

  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'version') {
      calls.add(method);
      return {'taskCacheRoots': true, 'directOutput': directOutputSupported};
    }
    if (method == 'begin' &&
        (args.str('outputPath').isNotEmpty || resumeLegacyCache)) {
      calls.add(method);
      begins.add({...args});
      final locator = args.str('outputPath').isNotEmpty
          ? args.str('outputPath')
          : p.join(
              args.str('cacheRoot', cache!),
              args.str('id'),
              'payload.gopeed',
            );
      final output = grantedFiles[locator] ?? File(locator);
      beginLengths.add(await output.length());
      outputs[args.str('id')] = output;
      outputLocators[args.str('id')] = locator;
      if (args.str('torrentData').isNotEmpty) torrents.add(args.str('id'));
      writer = true;
      if (await output.length() == 0) {
        await output.writeAsBytes(_content.sublist(0, 2));
      }
      return null;
    }
    final output = outputs[args.str('id')];
    if (method == 'remove' && output != null && holdRemoval != null) {
      if (!removalEntered.isCompleted) removalEntered.complete();
      await holdRemoval!.future;
    }
    if (method == 'snapshot' && output != null) {
      calls.add(method);
      if (finish) {
        final written = await output.length();
        await output.writeAsBytes(
          _content.sublist(written),
          mode: FileMode.append,
        );
        writer = seedAfterDone && torrents.contains(args.str('id'));
      }
      final written = await output.length();
      return {
        'status': finish ? 'done' : 'running',
        'total': _content.length,
        'downloaded': written,
        'speed': 0,
        'path': outputLocators[args.str('id')],
        'readableRanges': [
          [0, written],
        ],
      };
    }
    return super.call(method, args);
  }
}

class _TargetRecord {
  _TargetRecord({
    required this.file,
    required this.uri,
    required this.key,
    required this.name,
    required this.relativePath,
    required this.destination,
  });

  final File file;
  final String uri, key, name, relativePath;
  final String? destination;
  bool published = false, publishing = false;

  Json get description => {
    'exists': true,
    'uri': uri,
    'key': key,
    'name': name,
    'actualName': name,
    'relativePath': relativePath,
    'destination': destination,
    'published': published,
    'publishing': publishing,
  };
}

// The journal and the chosen files survive recreation of both platform fakes.
class _TargetJournal {
  final records = <String, _TargetRecord>{};
  final created = <_TargetRecord>[];
  int leaseGeneration = 0;
}

class _DirectFiles extends FileAccess {
  _DirectFiles(
    this.defaults,
    this.selected,
    this.journal,
    this.native,
    this.persistedTask,
  ) : destinations = {_destination: selected};

  final Directory defaults, selected;
  final Map<String, Directory> destinations;
  final _TargetJournal journal;
  final _DirectNative native;
  final Json Function(String id) persistedTask;
  final leases = <String, DirectDownloadTarget>{};
  final opened = <DirectDownloadTarget>[];
  final openRequests = <Json>[];
  final released = <DirectDownloadTarget>[];
  final discarded = <String>[];
  final forgotten = <String>[];
  static const channel = MethodChannel('asterlink/direct-output-fixture');
  final ioCalls = <Json>[];
  int saveCalls = 0, freeChecks = 0, availableBytes = 1 << 40;
  bool denyOpen = false,
      closedWhileWriting = false,
      forgotBeforeCommit = false,
      sameVolume = false,
      allowLegacySave = false;
  Future<void> Function()? afterFinish;
  Future<void> Function(String)? beforeForget;

  Directory directoryFor(String? destination) => destination == null
      ? defaults
      : destinations[destination] ?? (throw const AppException('下载目录不存在'));

  @override
  bool get directDownloads => true;

  @override
  Future<Json?> inspectDownloadTarget(String id) async =>
      journal.records[id]?.description;

  @override
  Future<DirectDownloadTarget> openDownloadTarget({
    required String id,
    required String name,
    required String relativePath,
    String? destination,
  }) async {
    openRequests.add({
      'id': id,
      'name': name,
      'relativePath': relativePath,
      'destination': destination,
    });
    if (denyOpen) throw const AppException('无法访问下载目标，请检查目录权限');
    var record = journal.records[id];
    if (record == null) {
      final directory = directoryFor(destination);
      final file = File(
        p.join(directory.path, safeRelativePath(relativePath), name),
      );
      await file.parent.create(recursive: true);
      await file.create(exclusive: true);
      record = _TargetRecord(
        file: file,
        uri: 'content://fixtures/document/$id',
        key: 'target-$id',
        name: name,
        relativePath: relativePath,
        destination: destination,
      );
      journal.records[id] = record;
      journal.created.add(record);
    }
    require(
      record.name == name &&
          record.relativePath == relativePath &&
          record.destination == destination,
      '下载目标身份发生变化',
    );
    var target = leases[id];
    if (target == null) {
      final generation = ++journal.leaseGeneration;
      // A locator must never be opened through dart:io. Only the platform
      // grant (mocked by access below) can read or write the chosen file.
      final locator = '/proc/self/fd/${1000000000 + generation}';
      final lease = 'lease-$generation';
      target = DirectDownloadTarget(
        uri: record.uri,
        path: locator,
        key: record.key,
        lease: lease,
        file: AndroidDownloadFile(
          path: locator,
          id: id,
          lease: lease,
          channel: channel,
        ),
      );
      leases[id] = target;
      native.grantedFiles[locator] = record.file;
    }
    opened.add(target);
    return target;
  }

  Future<Object?> access(MethodCall call) async {
    if (call.method != 'downloadTargetIo') throw MissingPluginException();
    final args = asJson(call.arguments);
    ioCalls.add(args);
    final id = args.str('id');
    final record = journal.records[id];
    if (record == null || leases[id]?.lease != args.str('lease')) {
      throw PlatformException(code: 'lease', message: '下载目标凭据已失效');
    }
    final operation = args.str('operation');
    if ((record.published || record.publishing) &&
        (operation == 'write' || operation == 'truncate')) {
      throw PlatformException(code: 'published', message: '文件已进入完成处理');
    }
    switch (operation) {
      case 'exists':
        return record.file.exists();
      case 'length':
        return record.file.length();
      case 'read':
        final handle = await record.file.open();
        try {
          await handle.setPosition(args.integer('offset'));
          return await handle.read(args.integer('length'));
        } finally {
          await handle.close();
        }
      case 'write':
      case 'truncate':
      case 'flush':
        final handle = await record.file.open(mode: FileMode.append);
        try {
          if (operation == 'write') {
            final bytes = args['data'] as Uint8List;
            await handle.setPosition(args.integer('offset'));
            await handle.writeFrom(bytes);
            return bytes.length;
          } else if (operation == 'truncate') {
            await handle.truncate(args.integer('length'));
          } else {
            await handle.flush();
          }
          return null;
        } finally {
          await handle.close();
        }
      default:
        throw StateError('Unexpected output operation: $operation');
    }
  }

  @override
  Future<String> finishDownloadTarget(
    String id,
    DirectDownloadTarget target,
    String name,
  ) async {
    final record = journal.records[id]!;
    require(
      leases[id]?.lease == target.lease && record.name == name,
      '下载目标凭据已失效',
    );
    closedWhileWriting |= native.writer;
    record.published = true;
    record.publishing = false;
    await afterFinish?.call();
    return record.uri;
  }

  @override
  Future<void> releaseDownloadTarget(
    String id,
    DirectDownloadTarget target,
  ) async {
    released.add(target);
    closedWhileWriting |= native.writer;
    if (leases[id]?.lease == target.lease) leases.remove(id);
  }

  @override
  Future<void> discardDownloadTarget(String id) async {
    final record = journal.records[id];
    if (record == null) return;
    require(!record.published && !record.publishing, '完成中的文件不能丢弃');
    closedWhileWriting |= native.writer;
    await record.file.delete();
    leases.remove(id);
    journal.records.remove(id);
    discarded.add(id);
  }

  @override
  Future<void> forgetDownloadTarget(String id) async {
    await beforeForget?.call(id);
    final record = journal.records[id];
    if (record == null) return;
    require(record.published, '下载尚未完成');
    final task = persistedTask(id);
    forgotBeforeCommit |=
        task.str('status') != 'completed' ||
        task.str('savedPath') != record.uri;
    closedWhileWriting |= native.writer;
    leases.remove(id);
    journal.records.remove(id);
    forgotten.add(id);
  }

  @override
  Future<StoragePlan> storagePlan(String cache, String? destination) async =>
      StoragePlan(
        StorageVolume('cache', cache),
        StorageVolume(
          sameVolume ? 'cache' : 'target',
          directoryFor(destination).path,
        ),
      );

  @override
  Future<FileAvailability> inspect(String? path) async =>
      path == null ? FileAvailability.missing : FileAvailability.present;

  @override
  Future<String?> chooseDirectory() async => _destination;

  @override
  Future<int> freeBytes(String path) async {
    freeChecks++;
    return availableBytes;
  }

  @override
  Future<void> cancelExport(String id) async {}

  @override
  Future<void> delete(String? path) async {
    for (final record in journal.created) {
      if (record.uri == path && await record.file.exists()) {
        await record.file.delete();
      }
    }
  }

  @override
  Future<String> save({
    required String id,
    required File source,
    required String name,
    required String relativePath,
    String? destination,
    required void Function() checkpoint,
    void Function(int copied, int total)? onProgress,
  }) async {
    saveCalls++;
    require(allowLegacySave, '直接下载不应复制缓存');
    checkpoint();
    final target = File(
      p.join(
        directoryFor(destination).path,
        safeRelativePath(relativePath),
        name,
      ),
    );
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    final bytes = await source.length();
    onProgress?.call(bytes, bytes);
    checkpoint();
    return target.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, defaults, selected, cache;
  late StateStore store;
  late _TargetJournal journal;
  late _DirectNative native;
  late _DirectFiles files;
  late _ProbeHttp http;
  late DownloadManager manager;
  var closed = true;

  Json persistedTask(String id) => (store.data['tasks'] as List? ?? [])
      .map(asJson)
      .firstWhere((task) => task.str('id') == id, orElse: () => {});

  Future<void> open({_ProbeHttp? transfer}) async {
    native = _DirectNative();
    files = _DirectFiles(defaults, selected, journal, native, persistedTask);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_DirectFiles.channel, files.access);
    http = transfer ?? _ProbeHttp();
    manager = DownloadManager(
      store: store,
      engine: GopeedEngine(
        native,
        store,
        Vault(store),
        Directory(p.join(root.path, 'native')),
        cache,
      ),
      files: files,
      cleanups: CleanupOutbox(store, FakeHttp()),
      http: http,
      refreshSource: (_) async =>
          throw const AppException('unexpected refresh'),
    );
    closed = false;
    await manager.initialize();
  }

  Future<void> close() async {
    if (closed) return;
    await manager.close();
    manager.dispose();
    http.dio.close(force: true);
    closed = true;
  }

  Future<void> settled(String id, DownloadStatus status) async {
    await until(() => !manager.task(id)!.active && manager.activeCount == 0);
    expect(manager.task(id)!.status, status, reason: manager.task(id)!.error);
  }

  Future<void> partial(String id) async {
    await until(
      () => manager.task(id)!.downloaded == 2 || !manager.task(id)!.active,
    );
    expect(
      manager.task(id)!.status,
      DownloadStatus.running,
      reason: manager.task(id)!.error,
    );
  }

  Future<void> noCachedPayload(String id) async {
    final taskCache = manager.engine.taskDirectory(id);
    expect(
      await File(p.join(taskCache.path, 'payload.gopeed')).exists(),
      isFalse,
    );
    expect(await File(p.join(taskCache.path, 'payload.hls')).exists(), isFalse);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-direct-output-');
    defaults = Directory(p.join(root.path, 'default-downloads'));
    selected = Directory(p.join(root.path, 'chosen-downloads'));
    cache = Directory(p.join(root.path, 'private-cache'));
    journal = _TargetJournal();
    store = StateStore.memory({
      'settings': {
        'concurrent': 1,
        'threads': 1,
        'retries': 0,
        'destination': _destination,
      },
    });
    await open();
  });

  tearDown(() async {
    await close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_DirectFiles.channel, null);
    final resolved = await root.resolveSymbolicLinks();
    require(
      p.isWithin(await Directory.systemTemp.resolveSymbolicLinks(), resolved) &&
          p.basename(resolved).startsWith('aster-direct-output-'),
      'unexpected test cleanup directory',
    );
    await root.delete(recursive: true);
  });

  test('native checksum mismatch never publishes the direct target', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_DirectFiles.channel, (call) async {
      if (call.method == 'verifyDownloadTarget') return '0' * 64;
      return files.access(call);
    });
    final id = await manager.enqueue(
      DownloadSpec.fromJson({
        ..._spec.toJson(),
        'checksumType': 'sha256',
        'checksumValue': sha256.convert(_content).toString(),
      }),
    );
    await settled(id, DownloadStatus.failed);
    expect(manager.task(id)!.error, contains('校验失败'));
    expect(journal.records[id]!.published, isFalse);
    expect(manager.task(id)!.payloadReady, isFalse);
    expect(await journal.records[id]!.file.readAsBytes(), _content);
  });

  test(
    'pausing native checksum joins the reader and preserves resumable bytes',
    () async {
      final entered = Completer<void>(), exited = Completer<String>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_DirectFiles.channel, (call) async {
        if (call.method == 'verifyDownloadTarget') {
          entered.complete();
          return exited.future;
        }
        if (call.method == 'cancelDownloadVerification') {
          exited.completeError(
            PlatformException(code: 'cancelled', message: '校验已暂停'),
          );
          return null;
        }
        return files.access(call);
      });
      final id = await manager.enqueue(
        DownloadSpec.fromJson({
          ..._spec.toJson(),
          'checksumType': 'sha256',
          'checksumValue': sha256.convert(_content).toString(),
        }),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      await manager.pause(id);
      await settled(id, DownloadStatus.paused);
      expect(journal.records[id]!.published, isFalse);
      expect(manager.task(id)!.payloadReady, isFalse);
      expect(await journal.records[id]!.file.readAsBytes(), _content);
      messenger.setMockMethodCallHandler(_DirectFiles.channel, files.access);
      await manager.resume(id);
      await settled(id, DownloadStatus.completed);
      expect(manager.task(id)!.savedPath, isNotNull);
      expect(files.forgotBeforeCommit, isFalse);
    },
  );

  test(
    'HTTP verifies the granted file and completes without reopening its locator',
    () async {
      native.finish = false;
      final id = await manager.enqueue(
        DownloadSpec.fromJson({
          ..._spec.toJson(),
          'checksumType': 'sha256',
          'checksumValue': sha256.convert(_content).toString(),
        }),
      );
      await partial(id);
      final record = journal.records[id]!;
      final target = files.opened.single;
      expect(await File(target.path).exists(), isFalse);
      expect(await record.file.readAsBytes(), [1, 2]);
      expect(p.isWithin(selected.path, record.file.path), isTrue);
      expect(files.openRequests.single['destination'], _destination);
      expect(
        files.openRequests.single['relativePath'],
        safeRelativePath(_spec.relativePath),
      );
      expect(native.begins.single['outputPath'], target.path);
      expect(native.begins.single['outputKey'], target.key);
      expect(manager.task(id)!.directOutput, isTrue);
      await noCachedPayload(id);
      native.finish = true;
      await settled(id, DownloadStatus.completed);
      expect(await record.file.readAsBytes(), _content);
      expect(manager.task(id)!.savedPath, record.uri);
      expect(persistedTask(id).str('savedPath'), record.uri);
      expect(files.saveCalls, 0);
      expect(files.forgotten, [id]);
      expect(files.forgotBeforeCommit, isFalse);
      expect(files.closedWhileWriting, isFalse);
      expect(files.leases, isEmpty);
      expect(
        files.ioCalls.map((call) => call.str('operation')),
        contains('read'),
      );
      expect(journal.records, isEmpty);
      expect(await defaults.exists(), isFalse);
      await noCachedPayload(id);
    },
  );

  test('the default download directory also receives bytes directly', () async {
    await manager.changeDestination(null);
    native.finish = false;
    final id = await manager.enqueue(_spec);
    await partial(id);
    final record = journal.records[id]!;
    expect(manager.task(id)!.destination, isNull);
    expect(files.openRequests.single['destination'], isNull);
    expect(p.isWithin(defaults.path, record.file.path), isTrue);
    expect(await record.file.readAsBytes(), [1, 2]);
    await noCachedPayload(id);
    native.finish = true;
    await settled(id, DownloadStatus.completed);
    expect(manager.task(id)!.savedPath, record.uri);
    expect(await record.file.readAsBytes(), _content);
    expect(files.saveCalls, 0);
    expect(await selected.exists(), isFalse);
  });

  test(
    'BT writes the selected file directly and stops seeding before publication',
    () async {
      const info = TorrentInfo(
        '0123456789012345678901234567890123456789',
        'BT 合集',
        '${torrentDataPrefix}Zml4dHVyZQ==',
        [TorrentFile(0, 'BT 合集/第一集.mp4', 4)],
        pieceLength: 16384,
      );
      native
        ..finish = false
        ..seedAfterDone = true;
      final id = (await manager.enqueueTorrent(info, [0])).single;
      await partial(id);
      final record = journal.records[id]!;
      final target = files.opened.single;
      expect(native.begins.single['outputPath'], target.path);
      expect(native.begins.single['outputKey'], target.key);
      expect(native.begins.single['torrentData'], info.data);
      expect(native.begins.single['torrentIndex'], 0);
      expect(p.isWithin(selected.path, record.file.path), isTrue);
      expect(await record.file.readAsBytes(), [1, 2]);
      await noCachedPayload(id);
      native.finish = true;
      await settled(id, DownloadStatus.completed);
      expect(http.probes, 0);
      expect(await record.file.readAsBytes(), _content);
      expect(manager.task(id)!.savedPath, record.uri);
      expect(files.saveCalls, 0);
      expect(files.closedWhileWriting, isFalse);
      expect(native.removedWhileWriting, isFalse);
      expect(files.forgotBeforeCommit, isFalse);
      expect(files.leases, isEmpty);
      await noCachedPayload(id);
    },
  );

  test(
    'one payload worth of space on a shared volume is enough to download',
    () async {
      files
        ..sameVolume = true
        ..availableBytes = manager.space.margin + _content.length + 1;
      native.finish = false;
      final id = await manager.enqueue(_spec);
      await partial(id);
      final record = journal.records[id]!;
      expect(files.freeChecks, greaterThan(0));
      expect(await record.file.readAsBytes(), [1, 2]);
      native.finish = true;
      await settled(id, DownloadStatus.completed);
      expect(await record.file.readAsBytes(), _content);
      expect(files.saveCalls, 0);
      await noCachedPayload(id);
    },
  );

  test(
    'changing the directory keeps existing output and updates only unstarted tasks',
    () async {
      final other = Directory(p.join(root.path, 'other-downloads'));
      files.destinations[_otherDestination] = other;
      native.finish = false;
      final started = await manager.enqueue(
        _spec.copyWith(fileName: 'started.bin'),
      );
      await partial(started);
      final original = journal.records[started]!;
      final queued = await manager.enqueue(
        _spec.copyWith(fileName: 'queued.bin'),
      );
      expect(manager.task(queued)!.status, DownloadStatus.pending);
      expect(journal.records.containsKey(queued), isFalse);
      final changed = await manager.changeDestination(
        _otherDestination,
        includeUnfinished: true,
      );
      expect(changed, 1);
      expect(manager.settings.destination, _otherDestination);
      expect(manager.task(started)!.destination, _destination);
      expect(manager.task(started)!.downloaded, 2);
      expect(await original.file.readAsBytes(), [1, 2]);
      expect(journal.records[started], same(original));
      expect(manager.task(queued)!.destination, _otherDestination);
      expect(manager.task(queued)!.status, DownloadStatus.paused);
      expect(journal.records.containsKey(queued), isFalse);
      native.finish = true;
      await manager.resume(started);
      await settled(started, DownloadStatus.completed);
      expect(manager.task(started)!.savedPath, original.uri);
      expect(await original.file.readAsBytes(), _content);
      await manager.resume(queued);
      await settled(queued, DownloadStatus.completed);
      final queuedFile = journal.created.singleWhere(
        (record) => record.uri == manager.task(queued)!.savedPath,
      );
      expect(p.isWithin(other.path, queuedFile.file.path), isTrue);
      expect(await queuedFile.file.readAsBytes(), _content);
      final fresh = await manager.enqueue(
        _spec.copyWith(fileName: 'fresh.bin'),
      );
      await settled(fresh, DownloadStatus.completed);
      final freshFile = journal.created.singleWhere(
        (record) => record.uri == manager.task(fresh)!.savedPath,
      );
      expect(manager.task(fresh)!.destination, _otherDestination);
      expect(p.isWithin(other.path, freshFile.file.path), isTrue);
      expect(await freshFile.file.readAsBytes(), _content);
      expect(files.discarded, isEmpty);
      expect(files.saveCalls, 0);
      expect(journal.created, hasLength(3));
    },
  );

  test(
    'pause and app restart reopen the same target and retain downloaded bytes',
    () async {
      native.finish = false;
      final id = await manager.enqueue(_spec);
      await partial(id);
      final record = journal.records[id]!;
      final first = files.opened.single;
      await manager.pause(id);
      expect(manager.task(id)!.status, DownloadStatus.paused);
      expect(await record.file.readAsBytes(), [1, 2]);
      expect(files.leases, isEmpty);
      expect(
        files.released.map((target) => target.lease),
        contains(first.lease),
      );
      expect(files.closedWhileWriting, isFalse);
      expect(persistedTask(id).toString(), isNot(contains(first.path)));
      expect(persistedTask(id).toString(), isNot(contains(first.lease)));
      await close();
      store = StateStore.memory(store.data);
      await open();
      await manager.resume(id);
      await settled(id, DownloadStatus.completed);
      final reopened = files.opened.single;
      expect(reopened.uri, first.uri);
      expect(reopened.key, first.key);
      expect(reopened.lease, isNot(first.lease));
      expect(reopened.path, isNot(first.path));
      expect(native.beginLengths, [2]);
      expect(await record.file.readAsBytes(), _content);
      expect(journal.created, hasLength(1));
      expect(files.saveCalls, 0);
      await noCachedPayload(id);
    },
  );

  test(
    'legacy Android cached progress resumes and exports without creating a direct target',
    () async {
      await close();
      const id = 'legacy-cached-download';
      final payload = File(p.join(cache.path, id, 'payload.gopeed'));
      await payload.parent.create(recursive: true);
      await payload.writeAsBytes([1, 2]);
      await store.put('tasks', [
        const DownloadTask(
          id: id,
          spec: _spec,
          createdAt: 0,
          status: DownloadStatus.paused,
          destination: _destination,
          total: 4,
          downloaded: 2,
          identity: _identity,
        ).toJson(),
      ]);
      await open();
      files.allowLegacySave = true;
      native
        ..resumeLegacyCache = true
        ..finish = false;
      await manager.resume(id);
      await until(
        () => native.beginLengths.isNotEmpty || !manager.task(id)!.active,
      );
      await partial(id);
      expect(manager.task(id)!.directOutput, isFalse);
      expect(await payload.readAsBytes(), [1, 2]);
      expect(native.beginLengths, [2]);
      expect(native.begins.single.str('outputPath'), isEmpty);
      expect(native.begins.single.str('outputKey'), isEmpty);
      expect(files.opened, isEmpty);
      expect(journal.created, isEmpty);
      native.finish = true;
      await settled(id, DownloadStatus.completed);
      final saved = File(manager.task(id)!.savedPath!);
      expect(p.isWithin(selected.path, saved.path), isTrue);
      expect(await saved.readAsBytes(), _content);
      expect(files.saveCalls, 1);
      expect(files.opened, isEmpty);
      expect(journal.created, isEmpty);
      expect(manager.task(id)!.directOutput, isFalse);
      expect(await payload.exists(), isFalse);
    },
  );

  test(
    'legacy Android empty tasks adopt direct output when first resumed',
    () async {
      await close();
      const id = 'legacy-empty-download';
      await store.put('tasks', [
        const DownloadTask(
          id: id,
          spec: _spec,
          createdAt: 0,
          status: DownloadStatus.paused,
          destination: _destination,
          total: 4,
        ).toJson(),
      ]);
      await open();
      expect(manager.task(id)!.directOutput, isFalse);
      expect(await manager.engine.taskDirectory(id).exists(), isFalse);
      await manager.resume(id);
      await settled(id, DownloadStatus.completed);
      final record = journal.created.single;
      expect(manager.task(id)!.directOutput, isTrue);
      expect(persistedTask(id).boolean('directOutput'), isTrue);
      expect(native.beginLengths, [0]);
      expect(native.begins.single['outputPath'], files.opened.single.path);
      expect(native.begins.single['outputKey'], record.key);
      expect(manager.task(id)!.savedPath, record.uri);
      expect(await record.file.readAsBytes(), _content);
      expect(files.saveCalls, 0);
      await noCachedPayload(id);
    },
  );

  test(
    'deleting an unfinished task stops its writer before removing the target',
    () async {
      native.finish = false;
      final id = await manager.enqueue(_spec);
      await partial(id);
      final record = journal.records[id]!;
      await manager.delete(id);
      await until(() => files.discarded.contains(id));
      expect(manager.task(id), isNull);
      expect(await record.file.exists(), isFalse);
      expect(journal.records, isEmpty);
      expect(files.leases, isEmpty);
      expect(files.closedWhileWriting, isFalse);
      expect(native.removedWhileWriting, isFalse);
    },
  );

  for (final deleteFile in [false, true]) {
    test(
      'deleting completed history ${deleteFile ? 'removes' : 'keeps'} the chosen file',
      () async {
        final id = await manager.enqueue(_spec);
        await settled(id, DownloadStatus.completed);
        final record = journal.created.single;
        expect(await record.file.readAsBytes(), _content);
        await manager.delete(id, deleteFile: deleteFile);
        await until(
          () => !(store.data['downloadRemovals'] as List? ?? []).contains(id),
        );
        expect(manager.task(id), isNull);
        expect(persistedTask(id), isEmpty);
        expect(await record.file.exists(), !deleteFile);
        if (!deleteFile) expect(await record.file.readAsBytes(), _content);
        expect(files.discarded, isEmpty);
        expect(files.closedWhileWriting, isFalse);
      },
    );
  }

  test(
    'missing destination permission fails without falling back to private cache',
    () async {
      files.denyOpen = true;
      final id = await manager.enqueue(_spec);
      await settled(id, DownloadStatus.failed);
      expect(manager.task(id)!.error, contains('目录权限'));
      expect(manager.task(id)!.savedPath, isNull);
      expect(native.begins, isEmpty);
      expect(files.saveCalls, 0);
      expect(journal.records, isEmpty);
      expect(await defaults.exists(), isFalse);
      await noCachedPayload(id);
    },
  );

  test('an older helper fails before it can start a cached download', () async {
    native.directOutputSupported = false;
    final id = await manager.enqueue(_spec);
    await settled(id, DownloadStatus.failed);
    expect(manager.task(id)!.error, contains('下载组件版本过旧'));
    expect(native.begins, isEmpty);
    expect(files.saveCalls, 0);
    await noCachedPayload(id);
  });

  test(
    'a missing target journal never treats BT sidecars as a cached payload',
    () async {
      await close();
      const id = 'missing-target-journal';
      final sidecar = File(p.join(cache.path, id, 'boundary-pieces', '0.part'));
      await sidecar.parent.create(recursive: true);
      await sidecar.writeAsBytes([9, 8]);
      await store.put('tasks', [
        const DownloadTask(
          id: id,
          spec: _spec,
          createdAt: 0,
          status: DownloadStatus.paused,
          destination: _destination,
          downloaded: 2,
          total: 4,
          directOutput: true,
          identity: _identity,
        ).toJson(),
      ]);
      await open();
      await manager.resume(id);
      await settled(id, DownloadStatus.failed);
      expect(manager.task(id)!.error, contains('下载目标记录已丢失'));
      expect(manager.task(id)!.directOutput, isTrue);
      expect(files.opened, isEmpty);
      expect(native.begins, isEmpty);
      expect(files.saveCalls, 0);
      expect(await sidecar.readAsBytes(), [9, 8]);
      await noCachedPayload(id);
    },
  );

  for (final published in [true, false]) {
    test(
      'recovers a ${published ? 'published' : 'publishing'} target without downloading again',
      () async {
        await close();
        const id = 'interrupted-publication';
        await files.openDownloadTarget(
          id: id,
          name: _spec.fileName,
          relativePath: _spec.relativePath,
          destination: _destination,
        );
        final record = journal.records[id]!;
        await record.file.writeAsBytes(_content);
        record.published = published;
        record.publishing = !published;
        await store.put('tasks', [
          const DownloadTask(
            id: id,
            spec: _spec,
            createdAt: 0,
            status: DownloadStatus.paused,
            destination: _destination,
            downloaded: 4,
            total: 4,
            payloadReady: true,
            directOutput: true,
            identity: _identity,
          ).toJson(),
        ]);
        store = StateStore.memory(store.data);
        await open();
        await manager.resume(id);
        await settled(id, DownloadStatus.completed);
        expect(http.probes, 0);
        expect(native.begins, isEmpty);
        expect(files.saveCalls, 0);
        expect(files.forgotten, [id]);
        expect(files.forgotBeforeCommit, isFalse);
        expect(manager.task(id)!.savedPath, record.uri);
        expect(await record.file.readAsBytes(), _content);
        expect(files.leases, isEmpty);
      },
    );
  }

  test(
    'a failed completed-state write retains the published file for restart recovery',
    () async {
      await close();
      final stateDirectory = Directory(p.join(root.path, 'state'));
      final key = Uint8List(32);
      store = await StateStore.open(stateDirectory, testKey: key);
      await store.put('settings', {
        'concurrent': 1,
        'threads': 1,
        'retries': 0,
        'destination': _destination,
      });
      await open();
      final blocked = Directory('${store.file!.path}.tmp');
      files.afterFinish = () async {
        await blocked.create();
      };
      try {
        final id = await manager.enqueue(_spec);
        await settled(id, DownloadStatus.failed);
        final record = journal.records[id]!;
        expect(record.published, isTrue);
        expect(await record.file.readAsBytes(), _content);
        expect(persistedTask(id).str('status'), isNot('completed'));
        expect(persistedTask(id)['savedPath'], isNull);
        expect(files.forgotten, isEmpty);
        expect(files.discarded, isEmpty);
        expect(files.leases, isEmpty);
        expect(manager.lastError, isNotNull);
        // Model process loss without committing the failed in-memory row.
        manager.dispose();
        await manager.engine.close();
        http.dio.close(force: true);
        closed = true;
        await blocked.delete();
        store = await StateStore.open(stateDirectory, testKey: key);
        expect(persistedTask(id)['savedPath'], isNull);
        await open();
        await manager.resume(id);
        await settled(id, DownloadStatus.completed);
        expect(http.probes, 0);
        expect(native.begins, isEmpty);
        expect(files.saveCalls, 0);
        expect(files.forgotten, [id]);
        expect(files.forgotBeforeCommit, isFalse);
        expect(manager.task(id)!.savedPath, record.uri);
        expect(persistedTask(id).str('savedPath'), record.uri);
        expect(await record.file.readAsBytes(), _content);
      } finally {
        if (await blocked.exists()) await blocked.delete();
      }
    },
  );

  test(
    'HLS resumes directly into the chosen file using its final extension',
    () async {
      await close();
      final playlist = _HlsHttp()..failSecond = true;
      await open(transfer: playlist);
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.invalid/video.m3u8',
          fileName: 'video.m3u8',
          relativePath: '影片',
        ),
      );
      await settled(id, DownloadStatus.failed);
      expect(manager.task(id)!.error, contains('视频分片暂不可用'));
      final record = journal.records[id]!;
      expect(record.name, 'video.ts');
      expect(p.isWithin(selected.path, record.file.path), isTrue);
      expect(await record.file.readAsBytes(), [1, 2]);
      expect(manager.task(id)!.hls.integer('index'), 1);
      expect(files.leases, isEmpty);
      await noCachedPayload(id);
      playlist.failSecond = false;
      await manager.resume(id);
      await settled(id, DownloadStatus.completed);
      expect(await record.file.readAsBytes(), _content);
      expect(manager.task(id)!.savedPath, record.uri);
      expect(
        playlist.requestedParts.where((name) => name == 'first.ts'),
        hasLength(1),
      );
      expect(journal.created, hasLength(1));
      expect(native.begins, isEmpty);
      expect(files.saveCalls, 0);
      expect(files.forgotBeforeCommit, isFalse);
      await noCachedPayload(id);
    },
  );

  test(
    'playback reads direct output and keeps the completed target open until release',
    () async {
      native.finish = false;
      final id = await manager.enqueue(_spec.copyWith(fileName: 'video.mp4'));
      await partial(id);
      final record = journal.records[id]!;
      final reader = await manager.acquirePlayback(id);
      try {
        expect(await reader.read(0, 1, _identity), [1, 2]);
        expect(await reader.read(2, 3, _identity), isNull);
        native.finish = true;
        await settled(id, DownloadStatus.completed);
        expect(await reader.read(0, 3, _identity), _content);
        expect(files.leases.containsKey(id), isTrue);
        expect(files.closedWhileWriting, isFalse);
      } finally {
        await reader.release();
      }
      await until(
        () => files.leases.isEmpty && !journal.records.containsKey(id),
      );
      expect(await record.file.readAsBytes(), _content);
      expect(files.forgotBeforeCommit, isFalse);
      expect(files.saveCalls, 0);
    },
  );

  test(
    'playback acquired during completed cleanup retains its target lease',
    () async {
      final releaseRemoval = Completer<void>();
      native.holdRemoval = releaseRemoval;
      addTearDown(() {
        if (!releaseRemoval.isCompleted) releaseRemoval.complete();
      });
      final id = await manager.enqueue(
        _spec.copyWith(fileName: 'cleanup-video.mp4'),
      );
      await native.removalEntered.future.timeout(const Duration(seconds: 5));
      expect(manager.task(id)!.status, DownloadStatus.completed);
      final record = journal.records[id]!;
      final reader = await manager
          .acquirePlayback(id)
          .timeout(const Duration(seconds: 5));
      try {
        releaseRemoval.complete();
        await settled(id, DownloadStatus.completed);
        expect(await reader.read(0, 3, _identity), _content);
        expect(files.leases.containsKey(id), isTrue);
        expect(journal.records[id], same(record));
      } finally {
        await reader.release();
      }
      await until(
        () => files.leases.isEmpty && !journal.records.containsKey(id),
      );
      expect(await record.file.readAsBytes(), _content);
      expect(files.closedWhileWriting, isFalse);
      expect(files.forgotBeforeCommit, isFalse);
    },
  );

  test(
    'next file can publish while completed cache removal is waiting',
    () async {
      final releaseRemoval = Completer<void>();
      final cleanupEntered = Completer<void>();
      files.beforeForget = (_) async {
        if (!cleanupEntered.isCompleted) cleanupEntered.complete();
        await releaseRemoval.future;
      };
      addTearDown(() {
        if (!releaseRemoval.isCompleted) releaseRemoval.complete();
      });
      final first = await manager.enqueue(
        _spec.copyWith(fileName: 'first.bin'),
      );
      await cleanupEntered.future.timeout(const Duration(seconds: 5));
      expect(persistedTask(first).str('status'), 'completed');
      final second = await manager.enqueue(
        _spec.copyWith(fileName: 'second.bin'),
      );
      await until(
        () => manager.task(second)!.status == DownloadStatus.completed,
      );
      expect(persistedTask(second).str('status'), 'completed');
      expect(journal.records[first]!.published, isTrue);
      expect(journal.records[second]!.published, isTrue);
      expect(releaseRemoval.isCompleted, isFalse);
      releaseRemoval.complete();
      await settled(second, DownloadStatus.completed);
      expect(files.forgotBeforeCommit, isFalse);
      expect(files.closedWhileWriting, isFalse);
    },
  );

  test(
    'releasing playback after pause closes its lease and keeps partial bytes',
    () async {
      native.finish = false;
      final id = await manager.enqueue(
        _spec.copyWith(fileName: 'paused-video.mp4'),
      );
      final reader = await manager.acquirePlayback(id);
      await partial(id);
      final record = journal.records[id]!;
      try {
        await manager.pause(id);
        expect(manager.task(id)!.status, DownloadStatus.paused);
        expect(await reader.read(0, 1, _identity), [1, 2]);
        expect(files.leases.containsKey(id), isTrue);
      } finally {
        await reader.release();
      }
      await until(() => files.leases.isEmpty);
      expect(await record.file.readAsBytes(), [1, 2]);
      expect(journal.records[id], same(record));
      expect(files.forgotten, isEmpty);
      expect(files.discarded, isEmpty);
      expect(files.closedWhileWriting, isFalse);
      await noCachedPayload(id);
    },
  );
}
