import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_qr.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'support.dart';

class _LocalIo extends HttpOverrides {}

class _ControlledFiles extends LanFiles {
  _ControlledFiles() : super(android: false);
  Completer<void>? gate;
  @override
  Future<void> check(LanLocalFile file) async {
    await gate?.future;
    await super.check(file);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LanService sender, receiver;
  late StateStore receiverStore;
  late _ControlledFiles sources;
  late HttpClient client;
  late DateTime now;
  final bytes = Uint8List.fromList(
    List.generate(512 * 1024 + 17, (i) => (i * 31) % 251),
  );
  const linkText = '我分享了资料 https://pan.baidu.com/s/1Example?pwd=abcd 提取码：abcd';

  Future<({int status, Uint8List bytes, Map<String, String> headers})> fetch(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(body is String ? body : jsonEncode(body)));
    }
    final response = await request.close().timeout(const Duration(seconds: 10));
    final data = BytesBuilder(copy: false);
    await for (final chunk in response) {
      data.add(chunk);
    }
    final values = <String, String>{};
    response.headers.forEach((name, parts) {
      values[name] = parts.join(',');
    });
    return (
      status: response.statusCode,
      bytes: data.takeBytes(),
      headers: values,
    );
  }

  Future<LanShare> share({
    bool folder = false,
    Duration? lifetime = const Duration(hours: 1),
  }) async {
    final location = folder
        ? p.join(root.path, '资料')
        : p.join(root.path, '资料', '演示 & 1.apk');
    return sender.createShare(
      await sources.scan([location], folder: folder),
      lifetime: lifetime,
    );
  }

  Future<LanPeer> paired(LanService from, LanService to) async {
    final peer = await from.findDevice(to.base().toString());
    await from.connect(peer, to.connectionCode);
    return peer;
  }

  setUp(() async {
    HttpOverrides.global = _LocalIo();
    root = await Directory.systemTemp.createTemp('aster-lan-service-');
    await Directory(p.join(root.path, '资料', '空目录')).create(recursive: true);
    await File(p.join(root.path, '资料', '演示 & 1.apk')).writeAsBytes(bytes);
    await File(p.join(root.path, '资料', '空文件.txt')).writeAsBytes([]);
    sources = _ControlledFiles();
    now = DateTime(2026, 10, 10, 12);
    receiverStore = StateStore.memory({'lanDeviceName': '接收手机'});
    LanService device(StateStore store, LanFiles files) => LanService(
      store: store,
      files: files,
      discoveryEnabled: false,
      requestedPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      addresses: () async => ['127.0.0.1'],
      clock: () => now,
    );
    sender = device(StateStore.memory({'lanDeviceName': '发送电脑'}), sources);
    receiver = device(receiverStore, LanFiles(android: false));
    client = HttpClient()
      ..maxConnectionsPerHost = 64
      ..findProxy = (_) => 'DIRECT';
    await sender.start();
    await receiver.start();
  });
  tearDown(() async {
    if (sources.gate != null && !sources.gate!.isCompleted) {
      sources.gate!.complete();
    }
    client.close(force: true);
    await sender.close();
    await receiver.close();
    await root.delete(recursive: true);
    HttpOverrides.global = null;
  });

  test(
    'Pairing is required, code stays private and a changed endpoint invalidates the session',
    () async {
      final peer = await receiver.findDevice(sender.base().toString());
      final info = await fetch(sender.base().replace(path: '/v1/info'));
      final public = asJson(jsonDecode(utf8.decode(info.bytes)));
      expect(public.keys.toSet(), {'protocol', 'id', 'name', 'port'});
      expect(
        await fetch(
          sender.base().replace(path: '/v1/shares'),
        ).then((r) => r.status),
        401,
      );
      final wrong = sender.connectionCode == '000000' ? '111111' : '000000';
      await expectLater(
        receiver.connect(peer, wrong),
        throwsA(isA<AppException>()),
      );
      expect(receiver.connected(peer), isFalse);
      await receiver.connect(peer, sender.connectionCode);
      expect(receiver.connected(peer), isTrue);
      expect(await receiver.remoteShares(peer), isEmpty);
      final moved = LanPeer(
        id: peer.id,
        name: peer.name,
        address: peer.address,
        port: peer.port == 65535 ? 1 : peer.port + 1,
        lastSeen: now,
      );
      expect(receiver.connected(moved), isFalse);
      await expectLater(
        receiver.remoteShares(moved),
        throwsA(isA<AppException>()),
      );
      now = now.add(const Duration(hours: 4));
      expect(receiver.connected(peer), isFalse);
      await expectLater(
        receiver.remoteShares(peer),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'Connection QR starts the receiver and pairs both directions over HTTP',
    () async {
      await receiver.stop();
      final qr = LanQrTarget.parse(sender.connectionQr()) as LanConnectionQr;
      expect(receiver.running, isFalse);
      final peer = await receiver.connectQr(qr);
      expect(receiver.running, isTrue);
      expect(receiver.connected(peer), isTrue);
      await receiver.sendMessage(peer, '扫码连接后的消息\n第二行');
      expect(sender.inbox.single.value, '扫码连接后的消息\n第二行');
      final other = sender.senderOf(sender.inbox.single)!;
      expect(sender.connected(other), isTrue);
      await sender.sendMessage(other, '电脑回复手机');
      expect(receiver.inbox.single.value, '电脑回复手机');
      final shared = await share();
      final fileQr =
          LanQrTarget.parse(sender.shareUrl(shared).toString()) as LanShareQr;
      final manifest = await receiver.readShare(fileQr.address.toString());
      final response = await fetch(
        Uri.parse(manifest.downloads(qr.address).single.url),
      );
      expect(response.status, 200);
      expect(response.bytes, bytes);
      expect(
        sha256.convert(response.bytes).toString(),
        manifest.files.single.sha256,
      );
    },
  );

  test(
    'Changed devices and expired connection codes cannot pair through old QR',
    () async {
      final qr = LanQrTarget.parse(sender.connectionQr()) as LanConnectionQr;
      final wrongDevice = LanConnectionQr(
        address: qr.address,
        deviceId: lanId(),
        code: qr.code,
      );
      await expectLater(
        receiver.connectQr(wrongDevice),
        throwsA(isA<AppException>()),
      );
      expect(receiver.connected(receiver.peers.single), isFalse);
      sender.connectionCode = qr.code == '000000' ? '111111' : '000000';
      await expectLater(receiver.connectQr(qr), throwsA(isA<AppException>()));
      expect(receiver.connected(receiver.peers.single), isFalse);
      await sender.stop();
      expect(() => sender.connectionQr(), throwsA(isA<AppException>()));
    },
  );

  test(
    'Connection code can select a discovered or manually found device',
    () async {
      await receiver.findDevice(sender.base().toString());
      final result = await receiver.connectCode(sender.connectionCode);
      expect(result.id, sender.id);
      expect(receiver.connected(result), isTrue);
      await expectLater(
        receiver.findDevice(receiver.base().toString()),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'A code is never sent to multiple nearby devices to find a match',
    () async {
      final other = LanService(
        store: StateStore.memory(),
        files: LanFiles(android: false),
        discoveryEnabled: false,
        requestedPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        addresses: () async => ['127.0.0.1'],
      );
      try {
        await other.start();
        final first = await receiver.findDevice(sender.base().toString());
        final second = await receiver.findDevice(other.base().toString());
        await expectLater(
          receiver.connectCode(sender.connectionCode),
          throwsA(isA<AppException>()),
        );
        expect(receiver.connected(first), isFalse);
        expect(receiver.connected(second), isFalse);
        await receiver.connect(first, sender.connectionCode);
        expect(receiver.connected(first), isTrue);
        expect(receiver.connected(second), isFalse);
      } finally {
        await other.close();
      }
    },
  );

  test(
    'Address refresh follows network changes and cannot restart a stopped listener',
    () async {
      var current = ['127.0.0.1'];
      Completer<List<String>>? pending;
      final refreshing = Completer<void>();
      final local = LanService(
        store: StateStore.memory(),
        files: LanFiles(android: false),
        discoveryEnabled: false,
        requestedPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        addresses: () async {
          if (pending != null) {
            refreshing.complete();
            return pending.future;
          }
          return current;
        },
      );
      try {
        await local.start();
        current = [];
        await local.refreshDevices();
        expect(local.addresses, isEmpty);
        expect(() => local.base(), throwsA(isA<AppException>()));
        current = ['192.168.1.12'];
        await local.refreshDevices();
        expect(local.base().host, '192.168.1.12');
        pending = Completer<List<String>>();
        final updating = local.refreshDevices();
        await refreshing.future;
        await local.stop();
        pending.complete(['192.168.2.12']);
        await updating;
        expect(local.running, isFalse);
        expect(local.port, 0);
      } finally {
        await local.close();
      }
    },
  );

  test('Incorrect codes are rate limited and recover after a minute', () async {
    final target = sender.base().replace(path: '/v1/pair');
    final wrong = sender.connectionCode == '000000' ? '111111' : '000000';
    for (var i = 0; i < 8; i++) {
      expect(
        (await fetch(target, method: 'POST', body: {'code': wrong})).status,
        403,
      );
    }
    expect(
      (await fetch(target, method: 'POST', body: {'code': wrong})).status,
      429,
    );
    now = now.add(const Duration(minutes: 1));
    expect(
      (await fetch(
        target,
        method: 'POST',
        body: {
          'code': sender.connectionCode,
          'id': receiver.id,
          'name': receiver.name,
        },
      )).status,
      200,
    );
  });

  test(
    'Links and file invitations enter a persistent inbox without automatic parsing',
    () async {
      final peer = await paired(sender, receiver);
      await sender.sendLink(peer, linkText);
      expect(receiver.unread, 1);
      expect(receiver.inbox.single.value, linkText);
      expect(receiver.inbox.single.sender, '发送电脑');
      final item = receiver.inbox.single;
      expect(receiverStore.data.list('lanInbox').single.str('value'), linkText);
      await receiver.markRead(item);
      expect(receiver.unread, 0);
      final shared = await share();
      await sender.sendShare(peer, shared);
      expect(receiver.inbox.first.kind, 'share');
      expect(Uri.parse(receiver.inbox.first.value).port, sender.port);
      final manifest = await receiver.readShare(receiver.inbox.first.value);
      expect(manifest.token, shared.manifest.token);
      await expectLater(
        sender.sendLink(peer, 'just some text'),
        throwsA(isA<AppException>()),
      );
      expect(receiver.inbox.length, 2);
      await receiver.markRead(item, remove: true);
      expect(receiver.inbox.length, 1);
    },
  );

  test(
    'One pairing permits replies and share discovery in both directions without UDP',
    () async {
      expect(receiver.peers, isEmpty);
      final peer = await paired(sender, receiver);
      final returnPeer = receiver.peers.single;
      expect(returnPeer.id, sender.id);
      expect(returnPeer.port, sender.port);
      expect(receiver.connected(returnPeer), isTrue);
      const text = '你好，手机 📱\n今晚八点见。\n这条消息没有下载链接。';
      await sender.sendMessage(peer, text);
      expect(receiver.inbox.single.kind, 'text');
      expect(receiver.inbox.single.value, text);
      expect(receiver.inbox.single.senderId, sender.id);
      expect(receiver.senderOf(receiver.inbox.single)?.id, sender.id);
      await receiver.sendMessage(returnPeer, '电脑已收到 ✅');
      expect(sender.inbox.single.value, '电脑已收到 ✅');
      expect(sender.inbox.single.senderId, receiver.id);
      final published = await share();
      expect(
        (await receiver.remoteShares(returnPeer)).single.token,
        published.manifest.token,
      );
      await sender.sendMessage(peer, linkText);
      expect(receiver.inbox.first.kind, 'link');
      expect(receiver.inbox.first.value, linkText);
      expect(receiver.unread, 2);
    },
  );

  test(
    'Text messages remain readable after stopping and reopening the service',
    () async {
      final peer = await paired(sender, receiver);
      const text = '第一行\n第二行带符号 <>&" 🚀\nhttps://example.com/普通网页';
      await sender.sendMessage(peer, text);
      final received = receiver.inbox.single;
      await receiver.close();
      receiver = LanService(
        store: receiverStore,
        files: LanFiles(android: false),
        discoveryEnabled: false,
        requestedPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        addresses: () async => ['127.0.0.1'],
        clock: () => now,
      );
      expect(receiver.running, isFalse);
      expect(receiver.inbox.single.value, text);
      expect(receiver.inbox.single.kind, 'text');
      expect(receiver.inbox.single.senderId, sender.id);
      expect(receiver.unread, 1);
      await receiver.markRead(received);
      expect(receiver.unread, 0);
      expect(
        receiverStore.data.list('lanInbox').single.boolean('read'),
        isTrue,
      );
      await receiver.markRead(received, remove: true);
      expect(receiverStore.data.list('lanInbox'), isEmpty);
    },
  );

  test(
    'Concurrent text sends are persisted once and reject empty or oversized messages',
    () async {
      final peer = await paired(sender, receiver);
      await Future.wait([
        for (var i = 0; i < 16; i++) sender.sendMessage(peer, '第 $i 条普通消息'),
      ]);
      expect(receiver.unread, 16);
      expect(receiver.inbox.map((item) => item.value).toSet().length, 16);
      expect(receiverStore.data.list('lanInbox'), hasLength(16));
      await expectLater(
        sender.sendMessage(peer, ' \n\t'),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        sender.sendMessage(
          peer,
          List.filled(lanMaxMessageLength + 1, '字').join(),
        ),
        throwsA(isA<AppException>()),
      );
      expect(receiver.unread, 16);
      final longest = List.filled(lanMaxMessageLength, '文').join();
      await sender.sendMessage(peer, longest);
      expect(receiver.inbox.first.value, longest);
    },
  );

  test(
    'Inbox rotation removes read history and never silently drops unread messages',
    () async {
      final oldest = LanInboxItem(
        id: lanId(),
        sender: '另一台设备',
        kind: 'text',
        value: '尚未阅读的重要消息',
        createdAt: 1,
      );
      await receiver.close();
      await receiverStore.put('lanInbox', [
        for (var i = 0; i < 99; i++)
          LanInboxItem(
            id: lanId(),
            sender: '设备',
            kind: 'text',
            value: '已读 $i',
            createdAt: 2,
            read: true,
          ).toJson(),
        oldest.toJson(),
      ]);
      receiver = LanService(
        store: receiverStore,
        files: LanFiles(android: false),
        discoveryEnabled: false,
        requestedPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        addresses: () async => ['127.0.0.1'],
        clock: () => now,
      );
      await receiver.start();
      final peer = await paired(sender, receiver);
      await sender.sendMessage(peer, '新的文字消息');
      expect(receiver.inbox, hasLength(100));
      expect(
        receiver.inbox.any((item) => item.id == oldest.id && !item.read),
        isTrue,
      );
      expect(receiver.unread, 2);
      for (var i = 0; i < 98; i++) {
        await sender.sendMessage(peer, '未读 $i');
      }
      expect(receiver.unread, 100);
      await expectLater(
        sender.sendMessage(peer, '满了也不能丢掉旧消息'),
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            contains('收件箱已满'),
          ),
        ),
      );
      expect(receiver.inbox.last.id, oldest.id);
      await receiver.markRead(receiver.inbox.first);
      await sender.sendMessage(peer, '处理后可以继续收到');
      expect(receiver.inbox.first.value, '处理后可以继续收到');
      expect(receiver.inbox.last.id, oldest.id);
    },
  );

  test(
    'Legacy one-way pairing stays compatible and duplicate messages are not repeated',
    () async {
      final paired = await fetch(
        receiver.base().replace(path: '/v1/pair'),
        method: 'POST',
        body: {
          'code': receiver.connectionCode,
          'id': sender.id,
          'name': sender.name,
        },
      );
      expect(paired.status, 200);
      final result = asJson(jsonDecode(utf8.decode(paired.bytes)));
      expect(result.boolean('bidirectional'), isFalse);
      final message = {'id': lanId(), 'kind': 'link', 'value': linkText};
      for (var i = 0; i < 2; i++) {
        final response = await fetch(
          receiver.base().replace(path: '/v1/inbox'),
          method: 'POST',
          body: message,
          headers: {'Authorization': 'Bearer ${result.str('session')}'},
        );
        expect(response.status, 200);
      }
      expect(receiver.inbox, hasLength(1));
      expect(receiver.inbox.single.kind, 'link');
      expect(receiver.inbox.single.value, linkText);
    },
  );

  test(
    'Restarting a peer expires old sessions and a fresh code restores both directions',
    () async {
      final peer = await paired(sender, receiver);
      await sender.sendMessage(peer, '重启前');
      final originalCode = receiver.connectionCode;
      await receiver.stop();
      await receiver.start();
      // A new listener can get the same or a different port; neither may reuse old credentials.
      final freshPeer = await sender.findDevice(receiver.base().toString());
      final wrong = receiver.connectionCode == originalCode
          ? (originalCode == '000000' ? '111111' : '000000')
          : originalCode;
      await expectLater(
        sender.connect(freshPeer, wrong),
        throwsA(isA<AppException>()),
      );
      await sender.connect(freshPeer, receiver.connectionCode);
      await sender.sendMessage(freshPeer, '重连成功');
      await receiver.sendMessage(receiver.peers.single, '恢复回复');
      expect(receiver.inbox.first.value, '重连成功');
      expect(sender.inbox.single.value, '恢复回复');
    },
  );

  test(
    'A legacy receiver keeps link delivery and explains unsupported text messages',
    () async {
      final legacyId = lanId(), legacyToken = lanId();
      final legacy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var links = 0;
      legacy.listen((request) async {
        final response = request.response;
        response.headers.contentType = ContentType.json;
        try {
          if (request.uri.path == '/v1/info') {
            response.write(
              jsonEncode({
                'protocol': lanProtocol,
                'id': legacyId,
                'name': '旧版设备',
                'port': legacy.port,
              }),
            );
          } else {
            final body = asJson(
              jsonDecode(await utf8.decoder.bind(request).join()),
            );
            if (request.uri.path == '/v1/pair') {
              response.write(
                jsonEncode({'session': legacyToken, 'id': legacyId}),
              );
            } else if (body.str('kind') == 'link') {
              links++;
              response.write(jsonEncode({'delivered': true}));
            } else {
              response.statusCode = 400;
              response.write(jsonEncode({'error': '消息格式无效'}));
            }
          }
        } finally {
          await response.close();
        }
      });
      try {
        final peer = await sender.findDevice('http://127.0.0.1:${legacy.port}');
        await sender.connect(peer, '123456');
        await sender.sendMessage(peer, linkText);
        expect(links, 1);
        await expectLater(
          sender.sendMessage(peer, '普通文字'),
          throwsA(
            isA<AppException>().having(
              (error) => error.message,
              'message',
              contains('更新对方'),
            ),
          ),
        );
        await sender.sendLink(peer, linkText);
        expect(links, 2);
      } finally {
        await legacy.close(force: true);
      }
    },
  );

  test(
    'A device address opens private browser pairing without exposing shares or codes',
    () async {
      final shared = await share();
      final response = await fetch(sender.base());
      expect(response.status, 200);
      expect(response.headers['content-type'], startsWith('text/html'));
      final page = utf8.decode(response.bytes);
      expect(page, contains('连接这台设备'));
      expect(page, contains('6 位连接码'));
      expect(page, isNot(contains('过期')));
      expect(page, isNot(contains(shared.manifest.token)));
      expect(page, isNot(contains(shared.manifest.files.single.name)));
      expect(page, isNot(contains(sender.connectionCode)));
      expect((await fetch(sender.base(), method: 'HEAD')).bytes, isEmpty);
      expect(
        (await fetch(sender.base().replace(path: '/favicon.ico'))).status,
        204,
      );
    },
  );

  for (final minutes in [15, 60, 240, 0]) {
    test(
      'Browser download stays valid for the $minutes minute option',
      () async {
        final startedAt = now;
        final shared = await share(
          lifetime: minutes == 0 ? null : Duration(minutes: minutes),
        );
        final address = sender.shareUrl(shared);
        expect(
          shared.manifest.expiresAt,
          minutes == 0 ? null : startedAt.add(Duration(minutes: minutes)),
        );
        for (final suffix in ['', '/']) {
          final pageUrl = address.replace(path: '${address.path}$suffix');
          final page = await fetch(pageUrl);
          expect(page.status, 200, reason: pageUrl.toString());
          expect((await fetch(pageUrl, method: 'HEAD')).status, 200);
          final downloadPath = RegExp(
            r'<a href="([^"]+)" download>',
          ).firstMatch(utf8.decode(page.bytes))!.group(1)!;
          final download = await fetch(pageUrl.resolve(downloadPath));
          expect(download.status, 200);
          expect(download.bytes, bytes);
          expect(sender.shares.single.manifest.token, shared.manifest.token);
        }
        now = minutes == 0
            ? now.add(const Duration(days: 3))
            : startedAt.add(
                Duration(minutes: minutes) - const Duration(milliseconds: 1),
              );
        expect((await fetch(address)).status, 200);
        if (minutes > 0) {
          now = now.add(const Duration(milliseconds: 1));
          expect((await fetch(address)).status, 410);
        }
      },
    );
  }

  test(
    'Whole-file, range, HEAD and browser downloads preserve name and bytes',
    () async {
      final shared = await share();
      final received = await receiver.readShare(
        sender.shareUrl(shared).toString(),
      );
      final url = Uri.parse(received.downloads(sender.base()).single.url);
      final whole = await fetch(url);
      expect(whole.status, 200);
      expect(whole.bytes, bytes);
      expect(
        sha256.convert(whole.bytes).toString(),
        received.files.single.sha256,
      );
      expect(
        whole.headers['content-disposition'],
        contains(Uri.encodeComponent('演示 & 1.apk')),
      );
      expect(whole.headers['accept-ranges'], 'bytes');
      final head = await fetch(url, method: 'HEAD');
      expect(head.status, 200);
      expect(head.bytes, isEmpty);
      expect(head.headers['content-length'], bytes.length.toString());
      final partial = await fetch(url, headers: {'Range': 'bytes=123-456'});
      expect(partial.status, 206);
      expect(partial.bytes, bytes.sublist(123, 457));
      expect(partial.headers['content-range'], 'bytes 123-456/${bytes.length}');
      final suffix = await fetch(url, headers: {'Range': 'bytes=-7'});
      expect(suffix.bytes, bytes.sublist(bytes.length - 7));
      final valid = await fetch(
        url,
        headers: {'Range': 'bytes=17-', 'If-Range': whole.headers['etag']!},
      );
      expect(valid.status, 206);
      expect(valid.bytes, bytes.sublist(17));
      final changed = await fetch(
        url,
        headers: {'Range': 'bytes=17-', 'If-Range': '"another-file"'},
      );
      expect(changed.status, 200);
      expect(changed.bytes, bytes);
      expect(
        (await fetch(url, headers: {'Range': 'bytes=0-1,4-5'})).status,
        416,
      );
      final browser = await fetch(sender.shareUrl(shared));
      expect(browser.status, 200);
      expect(utf8.decode(browser.bytes), contains('演示 &amp; 1.apk'));
      expect(
        browser.headers['content-security-policy'],
        contains("default-src 'none'"),
      );
      expect(utf8.decode(browser.bytes), isNot(contains(root.path)));
      await until(() => sender.activeConnections == 0);
    },
  );

  test(
    'Folders preserve nested and empty directories; empty files are downloadable',
    () async {
      final shared = await share(folder: true);
      expect(shared.manifest.singleFile, isFalse);
      expect(shared.manifest.directories.toSet(), {'资料', '资料/空目录'});
      expect(shared.manifest.files.map((f) => f.path).toSet(), {
        '资料/演示 & 1.apk',
        '资料/空文件.txt',
      });
      final destination = p.join(root.path, '收到');
      await receiver.files.createDirectories(
        destination,
        shared.manifest.directories,
      );
      expect(
        await Directory(p.join(destination, '资料', '空目录')).exists(),
        isTrue,
      );
      final specs = shared.manifest.downloads(sender.base());
      final empty = Uri.parse(
        specs.singleWhere((s) => s.expectedSize == 0).url,
      );
      expect((await fetch(empty)).bytes, isEmpty);
      final ranged = await fetch(empty, headers: {'Range': 'bytes=0-0'});
      expect(ranged.status, 416);
      expect(ranged.headers['content-range'], 'bytes */0');
      final browser = await fetch(sender.shareUrl(shared));
      expect(browser.status, 200);
      expect(utf8.decode(browser.bytes), contains('ZIP'));
    },
  );

  test(
    'Changed sources, expired/stopped tokens and unrelated paths never return file data',
    () async {
      final shared = await share(lifetime: const Duration(minutes: 15));
      final url = Uri.parse(
        shared.manifest.downloads(sender.base()).single.url,
      );
      now = now.add(const Duration(minutes: 15));
      expect((await fetch(url)).status, 410);
      final next = await share();
      final nextUrl = Uri.parse(
        next.manifest.downloads(sender.base()).single.url,
      );
      await File(
        p.join(root.path, '资料', '演示 & 1.apk'),
      ).writeAsString('changed');
      final changed = await fetch(nextUrl);
      expect(changed.status, 409);
      expect(utf8.decode(changed.bytes), contains('源文件已修改'));
      sender.stopShare(next);
      expect((await fetch(nextUrl)).status, 410);
      expect(
        (await fetch(sender.base().replace(path: '/v1/files'))).status,
        404,
      );
      final stray = await fetch(sender.base().replace(path: '/not-shared.txt'));
      expect(stray.status, 404);
      expect(utf8.decode(stray.bytes), isNot(contains(root.path)));
    },
  );

  test(
    'Preparation cancellation does not poison the long-lived HTTP server',
    () async {
      await sender.stop();
      final scope = RequestScope();
      await scope.run(sender.start);
      scope.cancel();
      final shared = await share();
      final url = Uri.parse(
        shared.manifest.downloads(sender.base()).single.url,
      );
      expect((await fetch(url)).bytes, bytes);
      final selection = await sources.scan([
        p.join(root.path, '资料', '演示 & 1.apk'),
      ]);
      await expectLater(
        scope.run(() => sender.createShare(selection)),
        throwsA(isA<AppException>()),
      );
      expect(sender.shares.length, 1);
    },
  );

  test(
    'Stopping new receivers preserves existing pause/resume transfer IDs',
    () async {
      final shared = await share();
      final old = Uri.parse(
        shared.manifest.downloads(sender.base()).single.url,
      );
      expect((await fetch(old, headers: {'Range': 'bytes=0-31'})).status, 206);
      sender.stopShare(shared, afterTransfers: true);
      final fresh = Uri.parse(
        shared.manifest.downloads(sender.base()).single.url,
      );
      expect((await fetch(fresh)).status, 400);
      now = now.add(const Duration(minutes: 5));
      final resumed = await fetch(old, headers: {'Range': 'bytes=32-'});
      expect(resumed.status, 206);
      expect(resumed.bytes, bytes.sublist(32));
      await expectLater(
        receiver.readShare(sender.shareUrl(shared).toString()),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'Busy sender returns retryable status and releases all reserved requests',
    () async {
      final shared = await share();
      final url = Uri.parse(
        shared.manifest.downloads(sender.base()).single.url,
      );
      sources.gate = Completer<void>();
      final pending = List.generate(
        32,
        (_) => fetch(url, headers: {'Range': 'bytes=0-0'}),
      );
      await until(() => sender.activeConnections == 32);
      final busy = await fetch(url, headers: {'Range': 'bytes=0-0'});
      expect(busy.status, 503);
      expect(busy.headers['retry-after'], '2');
      sources.gate!.complete();
      expect(
        (await Future.wait(pending)).every((r) => r.status == 206),
        isTrue,
      );
      await until(() => sender.activeConnections == 0);
    },
  );

  test(
    'Untrusted origins and malformed or oversized messages are rejected',
    () async {
      final target = sender.base().replace(path: '/v1/pair');
      expect(
        (await fetch(
          target,
          method: 'POST',
          headers: {'Origin': 'https://example.com'},
          body: {'code': sender.connectionCode},
        )).status,
        400,
      );
      expect(
        (await fetch(
          target,
          method: 'POST',
          headers: {'Host': 'example.com'},
          body: {},
        )).status,
        400,
      );
      expect(
        (await fetch(target, method: 'POST', body: '{broken')).status,
        400,
      );
      try {
        expect(
          (await fetch(
            target,
            method: 'POST',
            body: 'x' * (256 * 1024 + 1),
          )).status,
          400,
        );
      } on HttpException {
        // Rejecting an oversized chunked body may close its socket mid-upload.
      }
      expect(
        (await fetch(sender.base().replace(path: '/v1/info'))).status,
        200,
      );
    },
  );
}
