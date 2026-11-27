import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/download/space_budget.dart';
import 'package:asterlink/lan/lan_browser_receiver.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:asterlink/platform/file_access.dart';

import 'support.dart';

class _LocalIo extends HttpOverrides {}

class _Files extends PlatformFileAccess {
  _Files(super.transport, super.defaultDirectory);
  bool fail = false;
  int saveCount = 0;
  int available = 1 << 40;
  StoragePlan? plan;
  Completer<void>? saveGate, saveStarted;
  @override
  Future<int> freeBytes(String path) async => available;
  @override
  Future<StoragePlan> storagePlan(String cache, String? destination) async =>
      plan ?? await super.storagePlan(cache, destination);
  @override
  Future<String> save({
    required String id,
    required File source,
    required String name,
    required String relativePath,
    String? destination,
    required void Function() checkpoint,
    void Function(int, int)? onProgress,
  }) async {
    saveCount++;
    saveStarted?.complete();
    await saveGate?.future;
    checkpoint();
    if (fail) throw const AppException('模拟目录权限丢失');
    return super.save(
      id: id,
      source: source,
      name: name,
      relativePath: relativePath,
      destination: destination,
      checkpoint: checkpoint,
      onProgress: onProgress,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Files files;
  late LanBrowserReceiver receiver;
  late LanService service;
  late StateStore store;
  late SpaceBudget budget;
  late HttpClient client;
  late DateTime now;
  final bytes = Uint8List.fromList(
    List.generate(2 * 1024 * 1024 + 151, (i) => (i * 13) % 251),
  );

  Future<
    ({int status, Json json, Uint8List bytes, Map<String, String> headers})
  >
  request(
    String path, {
    String method = 'GET',
    Json? body,
    List<int>? data,
    String? cookie,
    Map<String, String> headers = const {},
  }) async {
    final req = await client.openUrl(method, service.base().resolve(path));
    req.followRedirects = false;
    if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie);
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    if (data != null) {
      req.headers.contentType = ContentType.binary;
      req.contentLength = data.length;
      req.add(data);
    }
    final res = await req.close().timeout(const Duration(seconds: 10));
    final result = BytesBuilder(copy: false);
    await for (final chunk in res) {
      result.add(chunk);
    }
    final content = result.takeBytes();
    final fields = <String, String>{};
    res.headers.forEach((name, values) => fields[name] = values.join(','));
    final json = res.headers.contentType?.mimeType == 'application/json'
        ? asJson(jsonDecode(utf8.decode(content)))
        : <String, dynamic>{};
    return (
      status: res.statusCode,
      json: json,
      bytes: content,
      headers: fields,
    );
  }

  Future<String> pair({String? cookie}) async {
    final res = await request(
      '/web/pair',
      method: 'POST',
      cookie: cookie,
      body: {'id': lanId(), 'name': '测试浏览器', 'code': service.connectionCode},
    );
    expect(res.status, 200);
    return res.headers['set-cookie']!.split(';').first;
  }

  Json metadata(
    List<int> data, {
    String? id,
    String path = '资料/浏览器 & 文件.txt',
    String? hash,
  }) => {
    'id': id ?? lanId(),
    'path': path,
    'size': data.length,
    'sha256': hash ?? sha256.convert(data).toString(),
  };

  Future<void> put(
    String cookie,
    Json meta,
    int start,
    List<int> part, {
    int status = 200,
  }) async {
    final res = await request(
      '/web/uploads/${meta.str('id')}',
      method: 'PUT',
      cookie: cookie,
      data: part,
      headers: {
        'Content-Range':
            'bytes $start-${start + part.length - 1}/${meta.integer('size')}',
      },
    );
    expect(res.status, status);
  }

  Future<LanBrowserUpload> finish(String cookie, Json meta) async {
    final res = await request(
      '/web/uploads/${meta.str('id')}/complete',
      method: 'POST',
      cookie: cookie,
    );
    expect(res.status, anyOf(200, 202));
    await until(
      () => receiver.records.any((u) => u.id == meta.str('id') && !u.busy),
    );
    return receiver.records.singleWhere((u) => u.id == meta.str('id'));
  }

  setUp(() async {
    HttpOverrides.global = _LocalIo();
    root = await Directory.systemTemp.createTemp('aster-browser-');
    now = DateTime(2026, 11, 24);
    store = StateStore.memory({});
    files = _Files(FakeNative(), Directory(p.join(root.path, 'saved')));
    budget = SpaceBudget(() => files.freeBytes(root.path), margin: 0);
    receiver = LanBrowserReceiver(
      store: store,
      cache: Directory(p.join(root.path, 'web-cache')),
      files: files,
      destination: () => null,
      budget: () => budget,
      clock: () => now,
    );
    service = LanService(
      store: store,
      files: LanFiles(android: false),
      browserReceiver: receiver,
      discoveryEnabled: false,
      requestedPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      addresses: () async => ['127.0.0.1'],
      clock: () => now,
    );
    client = HttpClient()
      ..maxConnectionsPerHost = 16
      ..findProxy = (_) => 'DIRECT';
    await service.start();
  });
  tearDown(() async {
    if (files.saveGate?.isCompleted == false) files.saveGate!.complete();
    client.close(force: true);
    await service.close();
    await root.delete(recursive: true);
    HttpOverrides.global = null;
  });

  test(
    'Anonymous page is offline, same-origin and reveals no code or shared filenames',
    () async {
      final source = File(p.join(root.path, 'private.txt'));
      await source.writeAsString('private');
      final share = await service.createShare(
        await service.files.scan([source.path]),
      );
      final home = await request('/');
      expect(home.status, 200);
      final text = utf8.decode(home.bytes);
      expect(text, contains('连接这台设备'));
      expect(text, isNot(contains(service.connectionCode)));
      expect(text, isNot(contains(share.manifest.token)));
      expect(text, isNot(contains('private.txt')));
      expect(
        home.headers['content-security-policy'],
        contains("script-src 'self'"),
      );
      expect((await request('/web/app.js')).status, 200);
      expect((await request('/web/sha256.js')).status, 200);
      expect(
        (await request('/web/app.css')).headers['content-type'],
        contains('text/css'),
      );
      expect((await request('/web/session')).status, 401);
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          body: metadata(bytes),
        )).status,
        401,
      );
      expect(
        (await request(
          '/web/pair',
          method: 'POST',
          body: {'code': service.connectionCode},
          headers: {'Origin': 'https://outside.example'},
        )).status,
        400,
      );
      final cookie = await pair();
      final paired = await request('/web/session', cookie: cookie);
      expect(paired.json.list('shares').single.str('name'), 'private.txt');
      expect(paired.json.keys, isNot(contains('connectionCode')));
      expect((await request('/v1/shares', cookie: cookie)).status, 401);
    },
  );

  test(
    'Browser PIN shares the existing attempt limit; cookie stays HttpOnly and isolated',
    () async {
      for (var i = 0; i < 8; i++) {
        final wrong = await request(
          '/web/pair',
          method: 'POST',
          body: {'id': lanId(), 'name': '网页', 'code': 'invalid'},
        );
        expect(wrong.status, 403);
      }
      expect(
        (await request(
          '/web/pair',
          method: 'POST',
          body: {'id': lanId(), 'name': '网页', 'code': service.connectionCode},
        )).status,
        429,
      );
      now = now.add(const Duration(minutes: 1));
      final result = await request(
        '/web/pair',
        method: 'POST',
        body: {'id': lanId(), 'name': '网页', 'code': service.connectionCode},
      );
      final set = result.headers['set-cookie']!.toLowerCase();
      expect(set, contains('httponly'));
      expect(set, contains('samesite=strict'));
      expect(set, contains('path=/web'));
      final cookie = result.headers['set-cookie']!.split(';').first;
      expect(await pair(cookie: cookie), cookie);
      expect(service.browserConnections, 1);
      expect(
        (await request(
          '/web/session',
          cookie: cookie,
          headers: {'X-AsterLink-Forwarded-Session': lanId()},
        )).status,
        isNot(200),
      );
    },
  );

  test(
    'Chunks, replay and completion save exact bytes once without overwriting names',
    () async {
      final cookie = await pair(), meta = metadata(bytes);
      final prepared = await request(
        '/web/uploads',
        method: 'POST',
        cookie: cookie,
        body: meta,
      );
      expect(prepared.status, 200);
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: cookie,
          body: meta,
        )).json.str('id'),
        meta.str('id'),
      );
      await put(cookie, meta, 0, bytes.sublist(0, lanBrowserChunkSize));
      await put(
        cookie,
        meta,
        0,
        bytes.sublist(0, lanBrowserChunkSize),
        status: 409,
      );
      expect(
        (await request(
          '/web/uploads/${meta.str('id')}',
          cookie: cookie,
        )).json.integer('offset'),
        lanBrowserChunkSize,
      );
      await put(
        cookie,
        meta,
        lanBrowserChunkSize,
        bytes.sublist(lanBrowserChunkSize),
      );
      final value = await finish(cookie, meta);
      expect(value.state, LanBrowserUploadState.completed);
      expect(await File(value.savedPath!).readAsBytes(), bytes);
      expect(
        await File(p.join(root.path, 'web-cache', '${value.id}.part')).exists(),
        isFalse,
      );
      await finish(cookie, meta);
      expect(files.saveCount, 1);
      expect(
        (await request(
          '/web/uploads/${value.id}',
          cookie: cookie,
        )).json.containsKey('savedPath'),
        isFalse,
      );
      final next = metadata([1, 2, 3]);
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: cookie,
          body: next,
        )).status,
        200,
      );
      await put(cookie, next, 0, [1, 2, 3]);
      final second = await finish(cookie, next);
      expect(p.basename(second.savedPath!), '浏览器 & 文件 (1).txt');
      expect(await File(value.savedPath!).readAsBytes(), bytes);
      expect(store.data.list('lanBrowserReceipts'), hasLength(2));
    },
  );

  test(
    'Names are safe, directory escapes, cross-owner access and oversized blocks fail',
    () async {
      final a = await pair(), b = await pair();
      final bad = metadata([1], path: '../outside.txt');
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: a,
          body: bad,
        )).status,
        400,
      );
      final meta = metadata(bytes, path: '资料/CON:<bad>.txt');
      final safe = await request(
        '/web/uploads',
        method: 'POST',
        cookie: a,
        body: meta,
      );
      expect(safe.status, 200);
      expect(safe.json.str('path'), '资料/CON__bad_.txt');
      expect(
        (await request('/web/uploads/${meta.str('id')}', cookie: b)).status,
        404,
      );
      expect(
        (await request(
          '/web/uploads/${meta.str('id')}',
          method: 'DELETE',
          cookie: b,
        )).status,
        404,
      );
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: b,
          body: meta,
        )).status,
        409,
      );
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: a,
          body: {...meta, 'sha256': '0' * 64},
        )).status,
        409,
      );
      await put(a, meta, 0, bytes, status: 413);
      expect(
        (await request(
          '/web/uploads/${meta.str('id')}/complete',
          method: 'POST',
          cookie: a,
        )).status,
        409,
      );
      expect(
        (await request(
          '/web/uploads/${meta.str('id')}',
          cookie: a,
        )).json.integer('offset'),
        0,
      );
    },
  );

  test(
    'A short or interrupted block leaves the acknowledged prefix unchanged',
    () async {
      final cookie = await pair(), meta = metadata([1, 2, 3, 4]);
      final prepared = await request(
        '/web/uploads',
        method: 'POST',
        cookie: cookie,
        body: meta,
      );
      final value = receiver.records.singleWhere(
        (u) => u.id == prepared.json.str('id'),
      );
      await expectLater(
        receiver.append(value.owner, value.id, 0, 4, Stream.value([1, 2])),
        throwsA(isA<LanBrowserException>()),
      );
      expect(value.offset, 0);
      expect(value.state, LanBrowserUploadState.paused);
      expect(
        await File(p.join(root.path, 'web-cache', '${value.id}.part')).length(),
        0,
      );
      final broken = Stream<List<int>>.multi((controller) {
        controller.add([1, 2]);
        controller.addError(const SocketException('simulated disconnect'));
        controller.close();
      });
      await expectLater(
        receiver.append(value.owner, value.id, 0, 4, broken),
        throwsA(isA<LanBrowserException>()),
      );
      expect(value.offset, 0);
      await put(cookie, meta, 0, [1, 2, 3, 4]);
      expect(
        await File((await finish(cookie, meta)).savedPath!).readAsBytes(),
        [1, 2, 3, 4],
      );
    },
  );

  test(
    'A file accepts one block at a time and the receiver limits total work',
    () async {
      final owner = lanId();
      final values = <LanBrowserUpload>[];
      for (var i = 0; i < 3; i++) {
        values.add(
          await receiver.prepare(owner, '网页', metadata([1], path: '$i.txt')),
        );
      }
      final a = StreamController<List<int>>(),
          b = StreamController<List<int>>();
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      final first = receiver.append(owner, values[0].id, 0, 1, a.stream);
      await until(() => values[0].state == LanBrowserUploadState.receiving);
      await expectLater(
        receiver.append(owner, values[0].id, 0, 1, Stream.value([1])),
        throwsA(
          isA<LanBrowserException>().having((e) => e.status, 'status', 409),
        ),
      );
      final second = receiver.append(owner, values[1].id, 0, 1, b.stream);
      await until(() => values[1].state == LanBrowserUploadState.receiving);
      expect(receiver.activeOperations, 2);
      await expectLater(
        receiver.append(owner, values[2].id, 0, 1, Stream.value([1])),
        throwsA(
          isA<LanBrowserException>().having((e) => e.status, 'status', 503),
        ),
      );
      a.add([1]);
      b.add([1]);
      await Future.wait([a.close(), b.close()]);
      await Future.wait([first, second]);
      expect(receiver.activeOperations, 0);
      await receiver.append(owner, values[2].id, 0, 1, Stream.value([1]));
      expect(values.map((u) => u.offset), everyElement(1));
    },
  );

  test(
    'HTTP capacity errors preserve progress and cancelled reservations are released',
    () async {
      files.available = 100;
      files.plan = StoragePlan(
        StorageVolume('volume', root.path),
        StorageVolume('volume', root.path),
      );
      await budget.reserveVolumes('other-download', {'volume': 80});
      final cookie = await pair(), rejected = metadata(List.filled(20, 1));
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: cookie,
          body: rejected,
        )).status,
        507,
      );
      expect(receiver.records, isEmpty);
      budget.release('other-download');
      final meta = metadata(List.filled(30, 1));
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: cookie,
          body: meta,
        )).status,
        200,
      );
      files.available = 10;
      await put(cookie, meta, 0, [1], status: 507);
      expect(
        (await request(
          '/web/uploads/${meta.str('id')}',
          cookie: cookie,
        )).json.integer('offset'),
        0,
      );
      files.available = 100;
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: cookie,
          body: metadata(List.filled(30, 1)),
        )).status,
        507,
      );
      expect(
        (await request(
          '/web/uploads/${meta.str('id')}',
          method: 'DELETE',
          cookie: cookie,
        )).status,
        200,
      );
      expect(
        (await request(
          '/web/uploads',
          method: 'POST',
          cookie: cookie,
          body: rejected,
        )).status,
        200,
      );
    },
  );

  test(
    'Idle cleanup, logout and session expiry cancel only unfinished payloads',
    () async {
      final cookie = await pair(), meta = metadata([1, 2]);
      await request('/web/uploads', method: 'POST', cookie: cookie, body: meta);
      now = now.add(const Duration(minutes: 29));
      receiver.prune();
      expect(receiver.records.single.state, LanBrowserUploadState.waiting);
      now = now.add(const Duration(minutes: 1));
      receiver.prune();
      await until(() => receiver.records.single.finished);
      await until(
        () => !File(
          p.join(root.path, 'web-cache', '${meta.str('id')}.part'),
        ).existsSync(),
      );
      expect(receiver.records.single.state, LanBrowserUploadState.cancelled);
      final saved = metadata([7], path: '保留.txt');
      await request(
        '/web/uploads',
        method: 'POST',
        cookie: cookie,
        body: saved,
      );
      await put(cookie, saved, 0, [7]);
      final receipt = await finish(cookie, saved);
      final abandoned = metadata([3], path: '退出.txt');
      await request(
        '/web/uploads',
        method: 'POST',
        cookie: cookie,
        body: abandoned,
      );
      expect(
        (await request('/web/logout', method: 'POST', cookie: cookie)).status,
        200,
      );
      expect((await request('/web/session', cookie: cookie)).status, 401);
      expect(
        receiver.records.singleWhere((u) => u.id == abandoned.str('id')).state,
        LanBrowserUploadState.cancelled,
      );
      expect(await File(receipt.savedPath!).readAsBytes(), [7]);
      final newCookie = await pair();
      now = now.add(const Duration(hours: 4));
      expect((await request('/web/session', cookie: newCookie)).status, 401);
    },
  );

  test(
    'Missing or changed receive cache never publishes corrupt files',
    () async {
      final cookie = await pair(), meta = metadata([1, 2]);
      await request('/web/uploads', method: 'POST', cookie: cookie, body: meta);
      await put(cookie, meta, 0, [1, 2]);
      final payload = File(
        p.join(root.path, 'web-cache', '${meta.str('id')}.part'),
      );
      await payload.delete();
      var value = await finish(cookie, meta);
      expect(value.error, contains('缓存已被移除'));
      expect(value.savedPath, isNull);
      expect(files.saveCount, 0);
      final changed = metadata([3, 4]);
      await request(
        '/web/uploads',
        method: 'POST',
        cookie: cookie,
        body: changed,
      );
      await put(cookie, changed, 0, [3, 4]);
      await File(
        p.join(root.path, 'web-cache', '${changed.str('id')}.part'),
      ).writeAsBytes([4, 3], flush: true);
      value = await finish(cookie, changed);
      expect(value.error, contains('校验不一致'));
      expect(value.offset, 0);
      expect(files.saveCount, 0);
    },
  );

  test(
    'Checksum mismatch remains retryable; empty files are verified and saved',
    () async {
      final cookie = await pair(),
          meta = metadata([
            1,
            2,
            3,
          ], hash: sha256.convert([3, 2, 1]).toString());
      await request('/web/uploads', method: 'POST', cookie: cookie, body: meta);
      await put(cookie, meta, 0, [1, 2, 3]);
      var value = await finish(cookie, meta);
      expect(value.state, LanBrowserUploadState.failed);
      expect(value.offset, 0);
      expect(files.saveCount, 0);
      await put(cookie, meta, 0, [3, 2, 1]);
      value = await finish(cookie, meta);
      expect(await File(value.savedPath!).readAsBytes(), [3, 2, 1]);
      final empty = metadata(const [], path: '空文件.txt');
      await request(
        '/web/uploads',
        method: 'POST',
        cookie: cookie,
        body: empty,
      );
      expect(await File((await finish(cookie, empty)).savedPath!).length(), 0);
    },
  );

  test(
    'A lost completion reply or parallel retry never repeats a slow platform export',
    () async {
      final cookie = await pair(), meta = metadata([1, 2, 3]);
      await request('/web/uploads', method: 'POST', cookie: cookie, body: meta);
      await put(cookie, meta, 0, [1, 2, 3]);
      files.saveGate = Completer<void>();
      files.saveStarted = Completer<void>();
      expect(
        (await request(
          '/web/uploads/${meta.str('id')}/complete',
          method: 'POST',
          cookie: cookie,
        )).status,
        202,
      );
      await files.saveStarted!.future;
      expect(
        (await request(
          '/web/uploads/${meta.str('id')}/complete',
          method: 'POST',
          cookie: cookie,
        )).status,
        202,
      );
      expect(files.saveCount, 1);
      files.saveGate!.complete();
      final value = await finish(cookie, meta);
      expect(value.state, LanBrowserUploadState.completed);
    },
  );

  test(
    'Export failure keeps verified bytes and retry saves without retransmission',
    () async {
      final cookie = await pair(), meta = metadata([1, 2, 3]);
      await request('/web/uploads', method: 'POST', cookie: cookie, body: meta);
      await put(cookie, meta, 0, [1, 2, 3]);
      files.fail = true;
      var value = await finish(cookie, meta);
      expect(value.state, LanBrowserUploadState.failed);
      expect(value.offset, 3);
      expect(value.savedPath, isNull);
      expect(
        await File(p.join(root.path, 'web-cache', '${value.id}.part')).length(),
        3,
      );
      files.fail = false;
      value = await finish(cookie, meta);
      expect(value.state, LanBrowserUploadState.completed);
      expect(await File(value.savedPath!).readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'Stopping during export cleans private payload and published receipt survives restart',
    () async {
      final cookie = await pair(), saved = metadata([1]);
      await request(
        '/web/uploads',
        method: 'POST',
        cookie: cookie,
        body: saved,
      );
      await put(cookie, saved, 0, [1]);
      final receipt = await finish(cookie, saved);
      final meta = metadata([1, 2, 3], path: 'cancelled.txt');
      await request('/web/uploads', method: 'POST', cookie: cookie, body: meta);
      await put(cookie, meta, 0, [1, 2, 3]);
      files.saveGate = Completer<void>();
      files.saveStarted = Completer<void>();
      await request(
        '/web/uploads/${meta.str('id')}/complete',
        method: 'POST',
        cookie: cookie,
      );
      await files.saveStarted!.future;
      final stopped = service.stop();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      files.saveGate!.complete();
      await stopped;
      expect(
        await Directory(p.join(root.path, 'web-cache')).list().toList(),
        isEmpty,
      );
      expect(await File(receipt.savedPath!).readAsBytes(), [1]);
      await service.start();
      expect((await request('/web/session', cookie: cookie)).status, 401);
      final restored = LanBrowserReceiver(
        store: store,
        cache: Directory(p.join(root.path, 'other-cache')),
        files: files,
        destination: () => null,
      );
      expect(restored.records.single.savedPath, receipt.savedPath);
      await restored.close();
    },
  );

  test(
    'Folder ZIP preserves Unicode names, nested bytes and empty directories',
    () async {
      final directory = Directory(p.join(root.path, '分享'));
      await Directory(p.join(directory.path, '空目录')).create(recursive: true);
      await File(p.join(directory.path, '内容.txt')).writeAsBytes(bytes);
      await File(p.join(directory.path, '空文件')).writeAsBytes([]);
      final share = await service.createShare(
        await service.files.scan([directory.path], folder: true),
      );
      final res = await request('/v1/zip/${share.manifest.token}');
      expect(res.status, 200);
      expect(res.headers['content-type'], contains('application/zip'));
      final archive = ZipDecoder().decodeBytes(res.bytes, verify: true);
      expect(archive.findFile('分享/内容.txt')!.readBytes(), bytes);
      expect(archive.findFile('分享/空文件')!.size, 0);
      expect(archive.findFile('分享/空目录/')!.isFile, isFalse);
      final cookie = await pair();
      expect((await request('/web/zip/${share.manifest.token}')).status, 401);
      expect(
        (await request(
          '/web/zip/${share.manifest.token}',
          cookie: cookie,
        )).status,
        200,
      );
      service.stopShare(share);
      expect((await request('/v1/zip/${share.manifest.token}')).status, 410);
    },
  );

  test(
    'Capacity uses the shared budget and release makes room for the next transfer',
    () async {
      final budget = SpaceBudget(() async => 100, margin: 0);
      await budget.reserveVolumes('download', {'volume': 60});
      await expectLater(
        budget.reserveVolumes('web', {
          'volume': 50,
        }, availableOnVolume: (_) async => 100),
        throwsA(isA<DownloadSpaceException>()),
      );
      budget.release('download');
      await budget.reserveVolumes('web', {
        'volume': 50,
      }, availableOnVolume: (_) async => 100);
    },
  );
}
