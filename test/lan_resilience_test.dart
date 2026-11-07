import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/lan/lan_download_route.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/lan/lan_models.dart';
import 'package:asterlink/lan/lan_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

class _LocalIo extends HttpOverrides {}

class _ObservedFiles extends LanFiles {
  _ObservedFiles() : super(android: false);
  bool interrupted = false;
  int openReads = 0;
  @override
  Stream<List<int>> read(LanLocalFile file, [int start = 0, int? end]) async* {
    openReads++;
    try {
      var first = true;
      await for (final chunk in super.read(file, start, end)) {
        yield chunk;
        if (interrupted && first) {
          first = false;
          throw const HttpException('Injected truncated file response');
        }
      }
    } finally {
      openReads--;
    }
  }
}

// Real HTTP/WebSocket sockets, with only the receiver -> sender route blocked.
// The already established sender -> receiver channel remains usable.
class _DeviceIo extends HttpOverrides {
  _DeviceIo(this.source);
  final String source;
  int? blockedPort;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = ((uri, _, _) {
          if (uri.port == blockedPort && uri.host.startsWith('127.')) {
            throw const SocketException('Injected one-way firewall');
          }
          return Socket.startConnect(uri.host, uri.port, sourceAddress: source);
        });
}

class _ScanIo extends HttpOverrides {
  _ScanIo(this.port);
  final int port;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = ((uri, _, _) {
          if (uri.host != '192.168.3.42' || uri.port != lanHttpPort) {
            throw const SocketException('No HTTP device on this address');
          }
          return Socket.startConnect(
            '127.0.0.1',
            port,
            sourceAddress: '127.0.0.2',
          );
        });
}

class _HttpRelay {
  _HttpRelay(this.target, this.server);
  final Uri target;
  final HttpServer server;
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  final sockets = <WebSocket>{};
  final sessions = <String>[], messageIds = <String>[];
  bool losePairReply = false, loseMessageReply = false;
  bool reverse = true;
  Uri get base => Uri(scheme: 'http', host: '127.0.0.2', port: server.port);

  static Future<_HttpRelay> open(Uri target) async {
    final relay = _HttpRelay(
      target,
      await HttpServer.bind(InternetAddress('127.0.0.2'), 0),
    );
    relay.server.listen((request) async {
      try {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final remote = await WebSocket.connect(
            target.replace(scheme: 'ws', path: request.uri.path).toString(),
            customClient: relay.client,
            compression: CompressionOptions.compressionOff,
            headers: {'Authorization': request.headers.value('Authorization')},
          );
          final local = await WebSocketTransformer.upgrade(
            request,
            compression: CompressionOptions.compressionOff,
          );
          relay.sockets.addAll([local, remote]);
          Future<void> closeSocket(WebSocket socket) async {
            try {
              await socket.close();
            } catch (_) {}
          }

          void forward(WebSocket socket, dynamic value) {
            try {
              socket.add(value);
            } catch (_) {
              unawaited(closeSocket(socket));
            }
          }

          local.listen(
            (value) => forward(remote, value),
            onDone: () {
              unawaited(closeSocket(remote));
              relay.sockets.remove(local);
            },
            onError: (Object _) => unawaited(closeSocket(remote)),
          );
          remote.listen(
            (value) => forward(local, value),
            onDone: () {
              unawaited(closeSocket(local));
              relay.sockets.remove(remote);
            },
            onError: (Object _) => unawaited(closeSocket(local)),
          );
          return;
        }
        final upstream = await relay.client.openUrl(
          request.method,
          target.resolveUri(request.uri),
        );
        final auth = request.headers.value('Authorization');
        if (auth != null) upstream.headers.set('Authorization', auth);
        if (request.method == 'POST') {
          final body = asJson(
            jsonDecode(await utf8.decoder.bind(request).join()),
          );
          if (request.uri.path == '/v1/pair' && !relay.reverse) {
            body.remove('reverseTransfer');
          }
          if (request.uri.path == '/v1/inbox') {
            relay.messageIds.add(body.str('id'));
          }
          upstream.headers.contentType = ContentType.json;
          upstream.write(jsonEncode(body));
        }
        final response = await upstream.close();
        final text = await utf8.decoder.bind(response).join();
        final data = asJson(jsonDecode(text));
        if (request.uri.path == '/v1/info') data['port'] = relay.server.port;
        if (request.uri.path == '/v1/pair') {
          relay.sessions.add(data.str('session'));
        }
        final lose =
            request.uri.path == '/v1/pair' && relay.losePairReply ||
            request.uri.path == '/v1/inbox' && relay.loseMessageReply;
        if (lose) {
          if (request.uri.path == '/v1/pair') relay.losePairReply = false;
          if (request.uri.path == '/v1/inbox') relay.loseMessageReply = false;
          (await request.response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        request.response.statusCode = response.statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(data));
        await request.response.close();
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    return relay;
  }

  Future<void> breakChannels() async {
    for (final socket in sockets.toList()) {
      await socket.close();
    }
    sockets.clear();
  }

  Future<void> close() async {
    await breakChannels();
    client.close(force: true);
    await server.close(force: true);
  }
}

void main() {
  late Directory root;
  late LanService sender, receiver;
  late _DeviceIo senderIo, receiverIo;
  late _ObservedFiles files;
  final payload = Uint8List.fromList(
    List.generate(2 * 1024 * 1024 + 17, (i) => (i * 31) % 251),
  );

  Future<T> fromSender<T>(Future<T> Function() operation) =>
      HttpOverrides.runWithHttpOverrides(operation, senderIo);
  Future<T> fromReceiver<T>(Future<T> Function() operation) =>
      HttpOverrides.runWithHttpOverrides(operation, receiverIo);

  Future<LanShare> shared() async {
    final file = await File(
      p.join(root.path, '原始文件.bin'),
    ).writeAsBytes(payload);
    return sender.createShare(await files.scan([file.path]));
  }

  Future<void> pair() async {
    await fromSender(() async {
      final peer = await sender.findDevice(receiver.base().toString());
      await sender.connect(peer, receiver.connectionCode);
    });
    await until(
      () => receiver.diagnostics.integer('reverseChannels') == 1,
      timeout: const Duration(seconds: 8),
    );
  }

  Future<({int status, List<int> bytes, Map<String, String> headers})> fetch(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Json? body,
  }) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.openUrl(method, uri);
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final bytes = await response.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      final values = <String, String>{};
      response.headers.forEach((key, value) => values[key] = value.join(', '));
      return (status: response.statusCode, bytes: bytes, headers: values);
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    HttpOverrides.global = _LocalIo();
    root = await Directory.systemTemp.createTemp('aster-lan-resilience-');
    files = _ObservedFiles();
    senderIo = _DeviceIo('127.0.0.1');
    receiverIo = _DeviceIo('127.0.0.2');
    Future<LanService> open(String address) async {
      final service = LanService(
        store: StateStore.memory(),
        files: files,
        discoveryEnabled: false,
        requestedPort: 0,
        bindAddress: InternetAddress(address),
        addresses: () async => [address],
      );
      await service.start();
      return service;
    }

    sender = await fromSender(() => open('127.0.0.1'));
    receiver = await fromReceiver(() => open('127.0.0.2'));
    receiverIo.blockedPort = sender.port;
  });

  tearDown(() async {
    await sender.close();
    await receiver.close();
    await root.delete(recursive: true);
    HttpOverrides.global = null;
  });

  test(
    'One-way pairing supports messages and verified invitations both ways',
    () async {
      await pair();
      final share = await shared();
      await fromSender(() => sender.sendShare(sender.peers.single, share));
      final message = receiver.inbox.single;
      expect(Uri.parse(message.value).host, '127.0.0.1');
      final manifest = await fromReceiver(
        () => receiver.readShare(message.value),
      );
      expect(manifest.token, share.manifest.token);
      await fromReceiver(
        () => receiver.sendMessage(receiver.peers.single, '反向回复'),
      );
      expect(sender.inbox.single.value, '反向回复');
      final reply = await receiver.createShare(
        await files.scan([
          (await File(p.join(root.path, '回复.txt')).writeAsString('reply')).path,
        ]),
      );
      await fromReceiver(
        () => receiver.sendShare(receiver.peers.single, reply),
      );
      expect(Uri.parse(sender.inbox.first.value).host, '127.0.0.2');
    },
  );

  test(
    'Blocked inbound HTTP still transfers four ranges with identical SHA256',
    () async {
      await pair();
      final share = await shared();
      final specs = receiver.prepareDownloads(share.manifest, sender.base());
      expect(LanDownloadRoute.owns(specs.single), isTrue);
      final route = await receiver.resolveDownload(specs.single);
      final uri = Uri.parse(route.url);
      final head = await fetch(uri, method: 'HEAD');
      expect(head.status, 200);
      expect(head.headers['content-length'], '${payload.length}');
      expect(head.headers['etag'], '"${sha256.convert(payload)}"');
      final parts = await Future.wait([
        for (var i = 0; i < 4; i++)
          fetch(
            uri,
            headers: {
              'Range':
                  'bytes=${payload.length * i ~/ 4}-${payload.length * (i + 1) ~/ 4 - 1}',
            },
          ),
      ]);
      final joined = <int>[];
      for (var i = 0; i < parts.length; i++) {
        expect(parts[i].status, 206);
        expect(
          parts[i].headers['content-range'],
          'bytes ${payload.length * i ~/ 4}-${payload.length * (i + 1) ~/ 4 - 1}/${payload.length}',
        );
        joined.addAll(parts[i].bytes);
      }
      expect(sha256.convert(joined), sha256.convert(payload));
      await until(
        () =>
            sender.activeConnections == 0 &&
            receiver.diagnostics.integer('reverseRequests') == 0,
      );
    },
  );

  test(
    'Routes survive serialization, reuse their key and rebuild after restart',
    () async {
      final share = await shared();
      final spec = receiver
          .prepareDownloads(share.manifest, sender.base())
          .single;
      final first = await receiver.resolveDownload(spec);
      final again = await receiver.resolveDownload(
        DownloadSpec.fromJson(first.toJson()),
      );
      expect(again.url, first.url);
      await receiver.stop();
      receiverIo.blockedPort = null;
      await receiver.start();
      final restored = await receiver.resolveDownload(
        DownloadSpec.fromJson(again.toJson()),
      );
      expect(Uri.parse(restored.url).port, receiver.port);
      final data = await fetch(
        Uri.parse(restored.url),
        headers: {'Range': 'bytes=12345-'},
      );
      expect(data.status, 206);
      expect(data.bytes, payload.sublist(12345));
    },
  );

  test(
    'Ended shares, changed files and invalid ranges retain their real errors',
    () async {
      await pair();
      final share = await shared();
      final route = await receiver.resolveDownload(
        receiver.prepareDownloads(share.manifest, sender.base()).single,
      );
      final uri = Uri.parse(route.url);
      expect(
        (await fetch(
          uri,
          headers: {'Range': 'bytes=${payload.length}-'},
        )).status,
        416,
      );
      await File(p.join(root.path, '原始文件.bin')).writeAsString('changed');
      expect((await fetch(uri)).status, 409);
      sender.stopShare(share);
      expect((await fetch(uri)).status, 410);
    },
  );

  test(
    'Forged forwarded permits and unauthenticated reverse channels are rejected',
    () async {
      final denied = await fetch(
        sender.base().replace(path: '/v1/shares'),
        headers: {'X-AsterLink-Forwarded-Session': lanId()},
      );
      expect(denied.status, 401);
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        await expectLater(
          WebSocket.connect(
            sender.base().replace(scheme: 'ws', path: '/v1/reverse').toString(),
            customClient: client,
          ),
          throwsA(isA<WebSocketException>()),
        );
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'Pair retries reuse sessions and message retries cannot duplicate or replace content',
    () async {
      final body = {
        'code': sender.connectionCode,
        'id': receiver.id,
        'name': receiver.name,
        'port': receiver.port,
        'replySession': lanId(),
        'reverseTransfer': true,
      };
      final first = await fetch(
        sender.base().replace(path: '/v1/pair'),
        method: 'POST',
        body: body,
      );
      final second = await fetch(
        sender.base().replace(path: '/v1/pair'),
        method: 'POST',
        body: body,
      );
      final info = asJson(jsonDecode(utf8.decode(first.bytes)));
      expect(second.bytes, first.bytes);
      final message = {'id': lanId(), 'kind': 'text', 'value': '只接收一次'};
      final headers = {'Authorization': 'Bearer ${info.str('session')}'};
      for (var i = 0; i < 2; i++) {
        expect(
          (await fetch(
            sender.base().replace(path: '/v1/inbox'),
            method: 'POST',
            body: message,
            headers: headers,
          )).status,
          200,
        );
      }
      expect(sender.inbox.length, 1);
      expect(
        (await fetch(
          sender.base().replace(path: '/v1/inbox'),
          method: 'POST',
          body: {...message, 'value': 'different'},
          headers: headers,
        )).status,
        400,
      );
      expect(sender.inbox.single.value, '只接收一次');
      expect(
        (await fetch(
          sender.base().replace(path: '/v1/pair'),
          method: 'POST',
          body: {...body, 'code': 'invalid'},
        )).status,
        403,
      );
    },
  );

  test(
    'A lost pairing or delivery response is retried without rotating the session or duplicating the inbox',
    () async {
      final relay = await fromSender(() => _HttpRelay.open(receiver.base()));
      relay.reverse = false;
      relay.losePairReply = true;
      relay.loseMessageReply = true;
      try {
        await fromSender(() async {
          final peer = await sender.findDevice(relay.base.toString());
          await sender.connect(peer, receiver.connectionCode);
          await sender.sendMessage(peer, '回复丢失后重试');
        });
        expect(relay.sessions, hasLength(2));
        expect(relay.sessions[0], relay.sessions[1]);
        expect(relay.messageIds, hasLength(2));
        expect(relay.messageIds[0], relay.messageIds[1]);
        expect(receiver.inbox, hasLength(1));
        expect(receiver.inbox.single.value, '回复丢失后重试');
      } finally {
        await relay.close();
      }
    },
  );

  test(
    'A dropped reverse channel reconnects and resumes the next range',
    () async {
      final relay = await fromSender(() => _HttpRelay.open(receiver.base()));
      try {
        await fromSender(() async {
          final peer = await sender.findDevice(relay.base.toString());
          await sender.connect(peer, receiver.connectionCode);
        });
        await until(() => receiver.diagnostics.integer('reverseChannels') == 1);
        final share = await shared();
        final route = await receiver.resolveDownload(
          receiver.prepareDownloads(share.manifest, sender.base()).single,
        );
        final first = await fetch(
          Uri.parse(route.url),
          headers: {'Range': 'bytes=0-65535'},
        );
        expect(first.status, 206);
        await relay.breakChannels();
        await until(() => receiver.diagnostics.integer('reverseChannels') == 0);
        await until(
          () => receiver.diagnostics.integer('reverseChannels') == 1,
          timeout: const Duration(seconds: 8),
        );
        final rest = await fetch(
          Uri.parse(route.url),
          headers: {'Range': 'bytes=65536-'},
        );
        expect(rest.status, 206);
        expect(
          sha256.convert([...first.bytes, ...rest.bytes]),
          sha256.convert(payload),
        );
      } finally {
        await relay.close();
      }
    },
  );

  test(
    'HTTP confirmation discovers both devices with no UDP traffic',
    () async {
      await receiver.close();
      final store = StateStore.memory({
        'lanKnownDevices': [
          {
            'id': sender.id,
            'name': sender.name,
            'address': sender.base().toString(),
          },
        ],
      });
      receiverIo.blockedPort = null;
      receiver = await fromReceiver(() async {
        final service = LanService(
          store: store,
          files: files,
          requestedPort: 0,
          unicastDiscovery: true,
          requestedDiscoveryPort: 0,
          bindAddress: InternetAddress('127.0.0.2'),
          addresses: () async => ['127.0.0.2'],
        );
        await service.start();
        return service;
      });
      await until(
        () =>
            receiver.peers.any((peer) => peer.id == sender.id) &&
            sender.peers.any((peer) => peer.id == receiver.id),
      );
      expect(receiver.connected(receiver.peers.single), isFalse);
      final before = sender.peers.single.lastSeen;
      await receiver.refreshDevices();
      await until(() => sender.peers.single.lastSeen.isAfter(before));
      await receiver.stop();
      expect(receiver.diagnostics.integer('peers'), 0);
      expect(receiver.diagnostics.boolean('httpDiscovery'), isFalse);
    },
  );

  test(
    'Cancelling a reversed file closes the sender reader and does not accumulate requests',
    () async {
      await pair();
      final share = await shared();
      final route = await receiver.resolveDownload(
        receiver.prepareDownloads(share.manifest, sender.base()).single,
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        for (var i = 0; i < 3; i++) {
          final response = await (await client.getUrl(
            Uri.parse(route.url),
          )).close();
          expect(response.statusCode, 200);
          await response.first;
          await until(
            () =>
                sender.activeConnections == 0 &&
                files.openReads == 0 &&
                receiver.diagnostics.integer('reverseRequests') == 0,
          );
        }
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'An interrupted body closes the response without appending JSON or a duplicate fallback body',
    () async {
      await pair();
      final share = await shared();
      final route = await receiver.resolveDownload(
        receiver.prepareDownloads(share.manifest, sender.base()).single,
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      final first = <int>[];
      files.interrupted = true;
      try {
        final response = await (await client.getUrl(
          Uri.parse(route.url),
        )).close();
        expect(response.statusCode, 200);
        Object? failure;
        try {
          await for (final chunk in response.timeout(
            const Duration(seconds: 5),
          )) {
            first.addAll(chunk);
          }
        } catch (error) {
          failure = error;
        }
        expect(failure, isNotNull);
        expect(first.length, inExclusiveRange(0, payload.length));
        expect(first, payload.sublist(0, first.length));
        files.interrupted = false;
        final remainder = await fetch(
          Uri.parse(route.url),
          headers: {'Range': 'bytes=${first.length}-'},
        );
        expect(remainder.status, 206);
        expect(
          sha256.convert([...first, ...remainder.bytes]),
          sha256.convert(payload),
        );
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'Out-of-order reverse data closes the channel and clears the pending request',
    () async {
      final body = {
        'code': receiver.connectionCode,
        'id': sender.id,
        'name': sender.name,
        'port': sender.port,
        'replySession': lanId(),
        'reverseTransfer': true,
      };
      final paired = await fetch(
        receiver.base().replace(path: '/v1/pair'),
        method: 'POST',
        body: body,
      );
      final token = asJson(
        jsonDecode(utf8.decode(paired.bytes)),
      ).str('session');
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      final socket = await WebSocket.connect(
        receiver.base().replace(scheme: 'ws', path: '/v1/reverse').toString(),
        headers: {'Authorization': 'Bearer $token'},
        customClient: client,
        compression: CompressionOptions.compressionOff,
      );
      socket.listen((dynamic message) {
        if (message is! String) return;
        final request = asJson(jsonDecode(message));
        if (request.str('kind') != 'request') return;
        final id = request.str('id');
        socket.add(
          jsonEncode({
            'kind': 'header',
            'id': id,
            'status': 200,
            'length': 10,
            'headers': {'content-length': '10'},
          }),
        );
        final frame = Uint8List(37);
        frame.setRange(0, 32, ascii.encode(id));
        ByteData.sublistView(
          frame,
          32,
          36,
        ).setUint32(0, 1); // Skip sequence zero.
        frame[36] = 1;
        socket.add(frame);
      });
      try {
        await until(() => receiver.diagnostics.integer('reverseChannels') == 1);
        await expectLater(
          fromReceiver(() => receiver.remoteShares(receiver.peers.single)),
          throwsA(isA<AppException>()),
        );
        await until(() => receiver.diagnostics.integer('reverseRequests') == 0);
        expect(receiver.diagnostics.integer('reverseChannels'), 0);
      } finally {
        await socket.close();
        client.close(force: true);
      }
    },
  );

  test(
    'Bounded subnet HTTP scanning finds a device when UDP has no replies',
    () async {
      await receiver.close();
      final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deviceId = lanId();
      var registered = 0;
      remote.listen((request) async {
        if (request.method == 'POST') {
          await request.drain<void>();
          registered++;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'protocol': lanProtocol,
            'id': deviceId,
            'name': 'HTTP only peer',
            'port': lanHttpPort,
          }),
        );
        await request.response.close();
      });
      try {
        receiver = await HttpOverrides.runWithHttpOverrides(() async {
          final service = LanService(
            store: StateStore.memory(),
            files: files,
            requestedPort: 0,
            requestedDiscoveryPort: 0,
            unicastDiscovery: true,
            bindAddress: InternetAddress('127.0.0.2'),
            addresses: () async => ['192.168.3.5'],
          );
          await service.start();
          return service;
        }, _ScanIo(remote.port));
        await until(
          () =>
              receiver.peers.any((peer) => peer.id == deviceId) &&
              registered == 1,
        );
        expect(receiver.peers.single.address, '192.168.3.42');
        expect(receiver.peers.single.port, lanHttpPort);
        await receiver.stop();
        expect(receiver.diagnostics.integer('httpProbes'), 0);
      } finally {
        await remote.close(force: true);
      }
    },
  );
}
